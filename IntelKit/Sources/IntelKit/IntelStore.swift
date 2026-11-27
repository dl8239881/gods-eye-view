import Foundation
import GRDB

/// On-device ontology store.
///
/// The database is one SQLite file (or memory). GRDB applies migrations the
/// first time a store is opened and on later launches. ``IntelStore`` can be
/// called from any thread: each method takes its own transaction on a serial
/// queue. Do not open a second store on the same file.
public final class IntelStore: @unchecked Sendable {
    /// Filesystem path, or nil for an in-memory store.
    public let path: String?
    private let queue: DatabaseQueue

    /// Opens or creates a database at `path`, including parent directories.
    public convenience init(path: String) throws {
        try self.init(queueAt: URL(fileURLWithPath: path))
    }

    /// Opens or creates a database at `url`.
    public static func onDisk(at url: URL) throws -> IntelStore {
        try IntelStore(queueAt: url)
    }

    /// An empty database that disappears when the store is released.
    public static func inMemory() throws -> IntelStore {
        let queue = try DatabaseQueue(configuration: configuration())
        return try IntelStore(queue: queue, path: nil)
    }

    private convenience init(queueAt url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if directory.path != url.path {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let queue = try DatabaseQueue(path: url.path, configuration: Self.configuration())
        try self.init(queue: queue, path: url.path)
    }

    private init(queue: DatabaseQueue, path: String?) throws {
        self.queue = queue
        self.path = path
        do {
            try IntelMigrations.migrator.migrate(queue)
        } catch let error as IntelError {
            throw error
        } catch {
            throw IntelError.database(String(describing: error))
        }
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "IntelKit"
        return configuration
    }

    /// Migration identifiers that have been applied, oldest first.
    public func appliedMigrations() throws -> [String] {
        try read { db in
            try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }
    }

    public func entityCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity") ?? 0
        }
    }

    public func linkCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM link") ?? 0
        }
    }

    public func entity(id: String) throws -> Entity? {
        try read { db in
            try entity(id: id, db: db)
        }
    }

    public func link(id: String) throws -> Link? {
        try read { db in
            try link(id: id, db: db)
        }
    }

    /// Inserts the entity, or replaces the row when the id already exists.
    public func upsert(_ entity: Entity) throws {
        _ = try upsert(entities: [entity], links: [])
    }

    /// Inserts the link, or replaces it when the id already exists.
    ///
    /// Both endpoints must already be in the store. The write is rolled back
    /// when they are not.
    public func upsert(_ link: Link) throws {
        _ = try upsert(entities: [], links: [link])
    }

    /// Writes entities first, then links, in one transaction.
    ///
    /// Duplicate ids in the arrays collapse to the last value. A thrown error
    /// leaves the database unchanged.
    @discardableResult
    public func upsert(entities: [Entity], links: [Link]) throws -> ImportResult {
        var entityByID: [String: Entity] = [:]
        for entity in entities {
            try entity.validate()
            entityByID[entity.id] = entity
        }
        var linkByID: [String: Link] = [:]
        for link in links {
            try link.validate()
            linkByID[link.id] = link
        }
        try write { db in
            for entity in entityByID.values {
                try EntityRow(entity).save(db)
            }
            for link in linkByID.values {
                guard try entityExists(link.fromID, db: db) else {
                    throw IntelError.notFound("Link \(link.id) starts at missing entity \(link.fromID)")
                }
                guard try entityExists(link.toID, db: db) else {
                    throw IntelError.notFound("Link \(link.id) ends at missing entity \(link.toID)")
                }
                try LinkRow(link).save(db)
            }
        }
        return ImportResult(entitiesUpserted: entityByID.count, linksUpserted: linkByID.count)
    }

    /// Deletes the entity and every link that touches it. Returns false when the id was absent.
    @discardableResult
    public func deleteEntity(id: String) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "DELETE FROM link WHERE fromID = ? OR toID = ?",
                arguments: [id, id]
            )
            try db.execute(sql: "DELETE FROM entity WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Deletes one link. Returns false when the id was absent.
    @discardableResult
    public func deleteLink(id: String) throws -> Bool {
        try write { db in
            try db.execute(sql: "DELETE FROM link WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Entities matching the filter, ordered by name (or by search rank when `name` is set).
    public func entities(matching filter: EntityFilter) throws -> [Entity] {
        try read { db in
            try entities(matching: filter, db: db)
        }
    }

    /// Folded substring search. An empty query returns no rows.
    ///
    /// Exact folded names come first, then prefix matches, then other substring
    /// matches. `limit` is clamped to 1000.
    public func search(name: String, kinds: Set<EntityKind> = [], limit: Int = 50) throws -> [Entity] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        }
        guard limit > 0 else {
            throw IntelError.validation("Search limit must be greater than zero")
        }
        return try entities(
            matching: EntityFilter(kinds: kinds, name: trimmed, limit: min(limit, 1_000))
        )
    }

    /// Entities whose folded name equals `name`.
    public func entities(exactlyNamed name: String) throws -> [Entity] {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).intelFolded()
        if folded.isEmpty {
            return []
        }
        return try read { db in
            let rows = try EntityRow.fetchAll(
                db,
                sql: "SELECT * FROM entity WHERE nameFolded = ? ORDER BY id",
                arguments: [folded]
            )
            return try rows.map { try $0.model() }
        }
    }

    /// Entities that have coordinates, for the globe.
    ///
    /// With a window, a pin is kept when its own time overlaps, or when it has
    /// no time and a link to some entity that does overlap. Kind filters still apply.
    public func globePins(
        in window: TimeWindow? = nil,
        kinds: Set<EntityKind> = []
    ) throws -> [GlobePin] {
        try read { db in
            let coordinated = try entities(
                matching: EntityFilter(kinds: kinds, requiresCoordinates: true),
                db: db
            )
            let kept: [Entity]
            if let window {
                let active = try entities(matching: EntityFilter(time: window), db: db)
                let linked = try idsTouching(Set(active.map(\.id)), db: db)
                kept = coordinated.filter { entity in
                    if window.overlaps(occurredAt: entity.occurredAt, endedAt: entity.endedAt) {
                        return true
                    }
                    return entity.occurredAt == nil && linked.contains(entity.id)
                }
            } else {
                kept = coordinated
            }
            return kept.compactMap { entity in
                guard let latitude = entity.latitude, let longitude = entity.longitude else {
                    return nil
                }
                return GlobePin(
                    id: entity.id,
                    name: entity.name,
                    kind: entity.kind,
                    latitude: latitude,
                    longitude: longitude,
                    occurredAt: entity.occurredAt,
                    endedAt: entity.endedAt
                )
            }
        }
    }

    /// Entities matching the filter, plus links whose endpoints are both included.
    ///
    /// When the filter has a time window, timeless entities that match the other
    /// constraints and share a link with a matching entity are included too.
    /// This is the slice a graph view draws for the current timeline position.
    public func subgraph(matching filter: EntityFilter = EntityFilter()) throws -> Subgraph {
        try read { db in
            var entities = try entities(matching: filter, db: db)
            var ids = Set(entities.map(\.id))
            if filter.time != nil, !ids.isEmpty {
                var contextFilter = filter
                contextFilter.time = nil
                let candidates = try self.entities(matching: contextFilter, db: db)
                let linked = try idsTouching(ids, db: db)
                for candidate in candidates
                where candidate.occurredAt == nil && linked.contains(candidate.id) && ids.insert(candidate.id).inserted
                {
                    entities.append(candidate)
                }
                entities.sort { lhs, rhs in
                    if lhs.name != rhs.name { return lhs.name < rhs.name }
                    return lhs.id < rhs.id
                }
            }
            guard !ids.isEmpty else {
                return Subgraph(entities: [], links: [])
            }
            let rows = try LinkRow.fetchAll(db, sql: "SELECT * FROM link")
            let links = try rows.map { try $0.model() }
                .filter { ids.contains($0.fromID) && ids.contains($0.toID) }
                .sorted { $0.id < $1.id }
            return Subgraph(entities: entities, links: links)
        }
    }

    /// Entities one hop from `entityID`.
    ///
    /// Throws ``IntelError/notFound(_:)`` when the origin is missing, so an
    /// isolated entity (an empty array) is distinct from a bad id. A time
    /// window drops neighbors that have a time outside the window, and keeps
    /// neighbors that have no time of their own.
    public func neighbors(
        of entityID: String,
        direction: LinkDirection = .both,
        linkTypes: Set<String>? = nil,
        time: TimeWindow? = nil
    ) throws -> [Neighbor] {
        try read { db in
            guard try entity(id: entityID, db: db) != nil else {
                throw IntelError.notFound("No entity with id \(entityID)")
            }
            return try neighbors(
                of: entityID,
                direction: direction,
                linkTypes: linkTypes,
                time: time,
                db: db
            )
        }
    }

    /// Breadth-first expansion out to `hops` links.
    ///
    /// The origin is always included, even when it falls outside `time`.
    /// Neighbors outside `time` are not returned and are not traversed.
    /// `hops` of 0 returns just the origin. `limit` caps the number of entities
    /// (default 500) so a dense graph cannot run away.
    public func expand(
        from entityID: String,
        hops: Int,
        direction: LinkDirection = .both,
        linkTypes: Set<String>? = nil,
        time: TimeWindow? = nil,
        limit: Int = 500
    ) throws -> Subgraph {
        guard hops >= 0 else {
            throw IntelError.validation("hops must be zero or greater")
        }
        guard limit >= 0 else {
            throw IntelError.validation("limit must be zero or greater")
        }
        return try read { db in
            guard let root = try entity(id: entityID, db: db) else {
                throw IntelError.notFound("No entity with id \(entityID)")
            }
            if limit == 0 {
                return Subgraph(entities: [], links: [])
            }
            var entities = [root]
            var seenEntities: Set<String> = [root.id]
            var links: [Link] = []
            var seenLinks: Set<String> = []
            var frontier = [root.id]
            var depth = 0
            while depth < hops, !frontier.isEmpty, entities.count < limit {
                var next: [String] = []
                for id in frontier {
                    let adjacent = try neighbors(
                        of: id,
                        direction: direction,
                        linkTypes: linkTypes,
                        time: time,
                        db: db
                    )
                    for neighbor in adjacent {
                        if seenLinks.insert(neighbor.link.id).inserted {
                            links.append(neighbor.link)
                        }
                        if seenEntities.insert(neighbor.entity.id).inserted {
                            entities.append(neighbor.entity)
                            next.append(neighbor.entity.id)
                            if entities.count >= limit {
                                break
                            }
                        }
                    }
                    if entities.count >= limit {
                        break
                    }
                }
                frontier = next
                depth += 1
            }
            return Subgraph(entities: entities, links: links)
        }
    }

    /// Simple paths from `originID` to `destinationID`, shortest first.
    ///
    /// `maxHops` counts links, not nodes. Paths do not repeat an entity, so a
    /// node is not a path to itself. The search stops after `limit` paths or
    /// after 10,000 partial paths, whichever comes first.
    public func paths(
        from originID: String,
        to destinationID: String,
        maxHops: Int = 4,
        direction: LinkDirection = .both,
        linkTypes: Set<String>? = nil,
        time: TimeWindow? = nil,
        limit: Int = 20
    ) throws -> [GraphPath] {
        guard maxHops >= 0 else {
            throw IntelError.validation("maxHops must be zero or greater")
        }
        guard limit > 0 else {
            throw IntelError.validation("Path limit must be greater than zero")
        }
        return try read { db in
            guard try entity(id: originID, db: db) != nil else {
                throw IntelError.notFound("No entity with id \(originID)")
            }
            guard try entity(id: destinationID, db: db) != nil else {
                throw IntelError.notFound("No entity with id \(destinationID)")
            }
            struct Step {
                var entityIDs: [String]
                var linkIDs: [String]
            }
            var queue = [Step(entityIDs: [originID], linkIDs: [])]
            var results: [GraphPath] = []
            var explored = 0
            while !queue.isEmpty, results.count < limit, explored < 10_000 {
                let step = queue.removeFirst()
                explored += 1
                let current = step.entityIDs[step.entityIDs.count - 1]
                if current == destinationID, !step.linkIDs.isEmpty {
                    results.append(try materialize(step.entityIDs, linkIDs: step.linkIDs, db: db))
                    continue
                }
                if step.linkIDs.count >= maxHops {
                    continue
                }
                let adjacent = try neighbors(
                    of: current,
                    direction: direction,
                    linkTypes: linkTypes,
                    time: time,
                    db: db
                )
                for neighbor in adjacent {
                    if step.entityIDs.contains(neighbor.entity.id) {
                        continue
                    }
                    queue.append(
                        Step(
                            entityIDs: step.entityIDs + [neighbor.entity.id],
                            linkIDs: step.linkIDs + [neighbor.link.id]
                        )
                    )
                }
            }
            return results
        }
    }

    private func materialize(_ entityIDs: [String], linkIDs: [String], db: Database) throws -> GraphPath {
        var entities: [Entity] = []
        for id in entityIDs {
            guard let entity = try entity(id: id, db: db) else {
                throw IntelError.notFound("No entity with id \(id)")
            }
            entities.append(entity)
        }
        var links: [Link] = []
        for id in linkIDs {
            guard let link = try link(id: id, db: db) else {
                throw IntelError.notFound("No link with id \(id)")
            }
            links.append(link)
        }
        return GraphPath(entities: entities, links: links)
    }

    private func entities(matching filter: EntityFilter, db: Database) throws -> [Entity] {
        var sql = "SELECT * FROM entity WHERE 1 = 1"
        var arguments = StatementArguments()
        if !filter.kinds.isEmpty {
            let kinds = filter.kinds.map(\.rawValue).sorted()
            sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))"
            arguments += StatementArguments(kinds)
        }
        let trimmedName = filter.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folded = trimmedName.intelFolded()
        let escaped = LikePattern.escape(folded)
        if !folded.isEmpty {
            sql += " AND nameFolded LIKE ? ESCAPE '\\'"
            arguments += StatementArguments(["%\(escaped)%"])
        }
        if filter.requiresCoordinates {
            sql += " AND latitude IS NOT NULL AND longitude IS NOT NULL"
        }
        if let time = filter.time {
            sql += " AND occurredAt IS NOT NULL"
            if let start = time.start {
                sql += " AND COALESCE(endedAt, occurredAt) >= ?"
                arguments += StatementArguments([start.timeIntervalSince1970])
            }
            if let end = time.end {
                sql += " AND occurredAt <= ?"
                arguments += StatementArguments([end.timeIntervalSince1970])
            }
        }
        if !folded.isEmpty {
            sql += """
                 ORDER BY CASE \
                WHEN nameFolded = ? THEN 0 \
                WHEN nameFolded LIKE ? ESCAPE '\\' THEN 1 \
                ELSE 2 END, name, id
                """
            arguments += StatementArguments([folded, "\(escaped)%"])
        } else {
            sql += " ORDER BY name, id"
        }
        if let limit = filter.limit {
            sql += " LIMIT ?"
            arguments += StatementArguments([max(limit, 0)])
        }
        let rows = try EntityRow.fetchAll(db, sql: sql, arguments: arguments)
        return try rows.map { try $0.model() }
    }

    private func neighbors(
        of entityID: String,
        direction: LinkDirection,
        linkTypes: Set<String>?,
        time: TimeWindow?,
        db: Database
    ) throws -> [Neighbor] {
        var pairs: [(Link, LinkDirection)] = []
        if direction == .outgoing || direction == .both {
            let rows = try links(column: "fromID", entityID: entityID, linkTypes: linkTypes, db: db)
            let models = try rows.map { try $0.model() }
            pairs.append(contentsOf: models.map { ($0, .outgoing) })
        }
        if direction == .incoming || direction == .both {
            let rows = try links(column: "toID", entityID: entityID, linkTypes: linkTypes, db: db)
            for row in rows {
                if direction == .both, row.fromID == row.toID {
                    continue
                }
                pairs.append((try row.model(), .incoming))
            }
        }
        var neighbors: [Neighbor] = []
        for (link, hop) in pairs {
            let otherID = hop == .outgoing ? link.toID : link.fromID
            guard let other = try entity(id: otherID, db: db) else {
                continue
            }
            if let time,
                other.occurredAt != nil,
                !time.overlaps(occurredAt: other.occurredAt, endedAt: other.endedAt)
            {
                continue
            }
            neighbors.append(Neighbor(entity: other, link: link, direction: hop))
        }
        return neighbors.sorted { lhs, rhs in
            if lhs.entity.name != rhs.entity.name {
                return lhs.entity.name < rhs.entity.name
            }
            return lhs.link.id < rhs.link.id
        }
    }

    private func links(
        column: String,
        entityID: String,
        linkTypes: Set<String>?,
        db: Database
    ) throws -> [LinkRow] {
        guard column == "fromID" || column == "toID" else {
            throw IntelError.database("Unexpected link column \(column)")
        }
        var sql = "SELECT * FROM link WHERE \(column) = ?"
        var arguments = StatementArguments([entityID])
        if let linkTypes {
            let types = linkTypes.sorted()
            if types.isEmpty {
                return []
            }
            sql += " AND type IN (\(types.map { _ in "?" }.joined(separator: ", ")))"
            arguments += StatementArguments(types)
        }
        sql += " ORDER BY id"
        return try LinkRow.fetchAll(db, sql: sql, arguments: arguments)
    }

    private func entity(id: String, db: Database) throws -> Entity? {
        guard let row = try EntityRow.fetchOne(db, sql: "SELECT * FROM entity WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return try row.model()
    }

    private func link(id: String, db: Database) throws -> Link? {
        guard let row = try LinkRow.fetchOne(db, sql: "SELECT * FROM link WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return try row.model()
    }

    /// Entity ids that share a link with `ids`, not including `ids` themselves.
    private func idsTouching(_ ids: Set<String>, db: Database) throws -> Set<String> {
        if ids.isEmpty {
            return []
        }
        let rows = try LinkRow.fetchAll(db, sql: "SELECT * FROM link")
        var touching: Set<String> = []
        for row in rows {
            if ids.contains(row.fromID) {
                touching.insert(row.toID)
            }
            if ids.contains(row.toID) {
                touching.insert(row.fromID)
            }
        }
        touching.subtract(ids)
        return touching
    }

    private func entityExists(_ id: String, db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM entity WHERE id = ? LIMIT 1", arguments: [id]) != nil
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try translate {
            try queue.read(body)
        }
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        try translate {
            try queue.write(body)
        }
    }

    private func translate<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as IntelError {
            throw error
        } catch {
            throw IntelError.database(String(describing: error))
        }
    }
}

enum IntelMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-entity-and-link") { db in
            try db.create(table: "entity") { table in
                table.primaryKey("id", .text)
                table.column("kind", .text).notNull()
                table.column("name", .text).notNull()
                table.column("nameFolded", .text).notNull().indexed()
                table.column("properties", .text).notNull()
                table.column("latitude", .double)
                table.column("longitude", .double)
                table.column("occurredAt", .double)
                table.column("endedAt", .double)
                table.column("source", .text).notNull()
                table.column("retrievedAt", .double).notNull()
                table.column("sourceURL", .text)
                table.column("externalID", .text)
            }
            try db.create(table: "link") { table in
                table.primaryKey("id", .text)
                table.column("type", .text).notNull().indexed()
                table.column("fromID", .text).notNull().indexed()
                    .references("entity", onDelete: .cascade)
                table.column("toID", .text).notNull().indexed()
                    .references("entity", onDelete: .cascade)
                table.column("properties", .text).notNull()
                table.column("source", .text).notNull()
                table.column("retrievedAt", .double).notNull()
                table.column("sourceURL", .text)
                table.column("externalID", .text)
            }
            try db.create(index: "entity_kind", on: "entity", columns: ["kind"])
            try db.create(index: "entity_occurredAt", on: "entity", columns: ["occurredAt"])
            try db.create(
                index: "entity_coordinates",
                on: "entity",
                columns: ["latitude", "longitude"]
            )
        }
        migrator.registerMigration("v2-external-id-index") { db in
            try db.create(index: "entity_externalID", on: "entity", columns: ["externalID"])
            try db.create(index: "link_externalID", on: "link", columns: ["externalID"])
        }
        return migrator
    }
}

struct EntityRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entity"

    var id: String
    var kind: String
    var name: String
    var nameFolded: String
    var properties: String
    var latitude: Double?
    var longitude: Double?
    var occurredAt: Double?
    var endedAt: Double?
    var source: String
    var retrievedAt: Double
    var sourceURL: String?
    var externalID: String?

    init(_ entity: Entity) throws {
        id = entity.id
        kind = entity.kind.rawValue
        name = entity.name
        nameFolded = entity.name.intelFolded()
        properties = try JSONCodec.encodeObject(entity.properties)
        latitude = entity.latitude
        longitude = entity.longitude
        occurredAt = entity.occurredAt?.timeIntervalSince1970
        endedAt = entity.endedAt?.timeIntervalSince1970
        source = entity.provenance.source
        retrievedAt = entity.provenance.retrievedAt.timeIntervalSince1970
        sourceURL = entity.provenance.sourceURL
        externalID = entity.provenance.externalID
    }

    func model() throws -> Entity {
        guard let kind = EntityKind(rawValue: kind) else {
            throw IntelError.database("Entity \(id) has unknown kind \(self.kind)")
        }
        return Entity(
            id: id,
            kind: kind,
            name: name,
            properties: try JSONCodec.decodeObject(properties),
            latitude: latitude,
            longitude: longitude,
            occurredAt: occurredAt.map(Date.init(timeIntervalSince1970:)),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:)),
            provenance: Provenance(
                source: source,
                retrievedAt: Date(timeIntervalSince1970: retrievedAt),
                sourceURL: sourceURL,
                externalID: externalID
            )
        )
    }
}

struct LinkRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "link"

    var id: String
    var type: String
    var fromID: String
    var toID: String
    var properties: String
    var source: String
    var retrievedAt: Double
    var sourceURL: String?
    var externalID: String?

    init(_ link: Link) throws {
        id = link.id
        type = link.type
        fromID = link.fromID
        toID = link.toID
        properties = try JSONCodec.encodeObject(link.properties)
        source = link.provenance.source
        retrievedAt = link.provenance.retrievedAt.timeIntervalSince1970
        sourceURL = link.provenance.sourceURL
        externalID = link.provenance.externalID
    }

    func model() throws -> Link {
        Link(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: try JSONCodec.decodeObject(properties),
            provenance: Provenance(
                source: source,
                retrievedAt: Date(timeIntervalSince1970: retrievedAt),
                sourceURL: sourceURL,
                externalID: externalID
            )
        )
    }
}
