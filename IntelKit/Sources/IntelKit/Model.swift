import Foundation

/// The kinds of thing an Intel graph can hold.
///
/// Vessel and aircraft are separate so a globe can style them differently
/// from a generic place. Importers also accept a few aliases (`ship`, `plane`,
/// `org`, `location`); anything else is rejected.
public enum EntityKind: String, Codable, CaseIterable, Sendable, Hashable {
    case person
    case organization
    case place
    case event
    case vessel
    case aircraft

    /// Maps importer spellings onto a kind. Returns nil when the token is unknown.
    public static func parse(_ raw: String) -> EntityKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).intelFolded() {
        case "person", "people", "individual":
            return .person
        case "organization", "organisation", "org", "company":
            return .organization
        case "place", "location", "geo", "country", "city":
            return .place
        case "event", "incident", "article":
            return .event
        case "vessel", "ship", "boat":
            return .vessel
        case "aircraft", "airplane", "plane":
            return .aircraft
        default:
            return nil
        }
    }
}

/// Conventional link types. The store accepts any non-empty string; these are
/// the ones GDELT import and the README examples use.
public enum LinkType {
    public static let reportedBy = "reported_by"
    public static let occurredIn = "occurred_in"
    public static let basedIn = "based_in"
    public static let mentions = "mentions"
    public static let affiliatedWith = "affiliated_with"
    public static let participatedIn = "participated_in"
    public static let locatedAt = "located_at"
    public static let operates = "operates"
}

/// Where a record came from, and when this device stored it.
public struct Provenance: Equatable, Sendable, Hashable {
    public var source: String
    /// When this device wrote the record, not when the world event happened.
    public var retrievedAt: Date
    public var sourceURL: String?
    public var externalID: String?

    public init(
        source: String,
        retrievedAt: Date,
        sourceURL: String? = nil,
        externalID: String? = nil
    ) {
        self.source = source
        self.retrievedAt = retrievedAt
        self.sourceURL = sourceURL
        self.externalID = externalID
    }
}

extension Provenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case source
        case retrievedAt
        case sourceURL
        case externalID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        retrievedAt = try CodableDate.decode(container, .retrievedAt) ?? Date(timeIntervalSince1970: 0)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(IntelDate.iso8601(retrievedAt), forKey: .retrievedAt)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(externalID, forKey: .externalID)
    }
}

/// One node in the ontology: a person, organization, place, event, vessel, or aircraft.
///
/// `latitude` and `longitude` are both set or both absent. A globe pin is an
/// entity that has both. `occurredAt` / `endedAt` are the time the record is
/// about (an event window, a sighting), which is what a timeline scrubber filters on.
public struct Entity: Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var kind: EntityKind
    public var name: String
    public var properties: [String: JSONValue]
    public var latitude: Double?
    public var longitude: Double?
    public var occurredAt: Date?
    public var endedAt: Date?
    public var provenance: Provenance

    public init(
        id: String,
        kind: EntityKind,
        name: String,
        properties: [String: JSONValue] = [:],
        latitude: Double? = nil,
        longitude: Double? = nil,
        occurredAt: Date? = nil,
        endedAt: Date? = nil,
        provenance: Provenance
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.properties = properties
        self.latitude = latitude
        self.longitude = longitude
        self.occurredAt = occurredAt
        self.endedAt = endedAt
        self.provenance = provenance
    }

    public var hasCoordinates: Bool {
        latitude != nil && longitude != nil
    }

    /// Keeps this record, and fills only the fields the other record has and this one lacks.
    func fillingGaps(from incoming: Entity) -> Entity {
        var result = self
        if result.latitude == nil, let latitude = incoming.latitude, let longitude = incoming.longitude {
            result.latitude = latitude
            result.longitude = longitude
        }
        if result.occurredAt == nil {
            result.occurredAt = incoming.occurredAt
        }
        if result.endedAt == nil {
            result.endedAt = incoming.endedAt
        }
        if Self.isWeakName(result.name), !Self.isWeakName(incoming.name) {
            result.name = incoming.name
        }
        for (key, value) in incoming.properties where result.properties[key] == nil {
            result.properties[key] = value
        }
        if result.provenance.sourceURL == nil {
            result.provenance.sourceURL = incoming.provenance.sourceURL
        }
        if result.provenance.externalID == nil {
            result.provenance.externalID = incoming.provenance.externalID
        }
        return result
    }

    func validate() throws {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Entity id is empty")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Entity \(id) has an empty name")
        }
        if provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Entity \(id) has an empty provenance source")
        }
        switch (latitude, longitude) {
        case (nil, nil):
            break
        case let (latitude?, longitude?):
            guard latitude.isFinite, longitude.isFinite else {
                throw IntelError.validation("Entity \(id) has a non-finite coordinate")
            }
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw IntelError.validation("Entity \(id) has a coordinate outside the valid range")
            }
        default:
            throw IntelError.validation("Entity \(id) has only one of latitude and longitude")
        }
        if let occurredAt, let endedAt, endedAt < occurredAt {
            throw IntelError.validation("Entity \(id) ends before it starts")
        }
    }

    private static func isWeakName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
    }
}

extension Entity: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case properties
        case latitude
        case longitude
        case occurredAt
        case endedAt
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(EntityKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        occurredAt = try CodableDate.decode(container, .occurredAt)
        endedAt = try CodableDate.decode(container, .endedAt)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(longitude, forKey: .longitude)
        try CodableDate.encode(occurredAt, to: &container, key: .occurredAt)
        try CodableDate.encode(endedAt, to: &container, key: .endedAt)
        try container.encode(provenance, forKey: .provenance)
    }
}

/// A typed directed relationship between two entities.
public struct Link: Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var type: String
    public var fromID: String
    public var toID: String
    public var properties: [String: JSONValue]
    public var provenance: Provenance

    public init(
        id: String,
        type: String,
        fromID: String,
        toID: String,
        properties: [String: JSONValue] = [:],
        provenance: Provenance
    ) {
        self.id = id
        self.type = type
        self.fromID = fromID
        self.toID = toID
        self.properties = properties
        self.provenance = provenance
    }

    func validate() throws {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Link id is empty")
        }
        if type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Link \(id) has an empty type")
        }
        if fromID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || toID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw IntelError.validation("Link \(id) is missing an endpoint")
        }
        if provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntelError.validation("Link \(id) has an empty provenance source")
        }
    }
}

extension Link: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case fromID
        case toID
        case properties
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        fromID = try container.decode(String.self, forKey: .fromID)
        toID = try container.decode(String.self, forKey: .toID)
        properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(fromID, forKey: .fromID)
        try container.encode(toID, forKey: .toID)
        try container.encode(properties, forKey: .properties)
        try container.encode(provenance, forKey: .provenance)
    }
}

/// Inclusive window over entity time. A nil bound is open on that side.
///
/// An entity matches when its `[occurredAt, endedAt]` interval overlaps the
/// window. ``IntelStore/entities(matching:)`` uses that strict test, so a
/// timeless record (no `occurredAt`) is left out. Traversal, ``IntelStore/subgraph(matching:)``,
/// and ``IntelStore/globePins(in:kinds:)`` still keep a timeless neighbor when
/// it shares a link with a record inside the window: a scrubber can hide
/// events outside the range without dropping the actors and places those
/// events are attached to.
public struct TimeWindow: Equatable, Sendable, Hashable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func overlaps(occurredAt: Date?, endedAt: Date?) -> Bool {
        guard let occurredAt else {
            return false
        }
        let entityEnd = endedAt ?? occurredAt
        if let start, entityEnd < start {
            return false
        }
        if let end, occurredAt > end {
            return false
        }
        return true
    }
}

/// Filter for ``IntelStore/entities(matching:)`` and ``IntelStore/subgraph(matching:)``.
///
/// An empty `kinds` set means every kind. `name` is a folded substring, the
/// same comparison ``IntelStore/search(name:kinds:limit:)`` uses.
public struct EntityFilter: Equatable, Sendable {
    public var kinds: Set<EntityKind>
    public var time: TimeWindow?
    public var name: String?
    public var requiresCoordinates: Bool
    public var limit: Int?

    public init(
        kinds: Set<EntityKind> = [],
        time: TimeWindow? = nil,
        name: String? = nil,
        requiresCoordinates: Bool = false,
        limit: Int? = nil
    ) {
        self.kinds = kinds
        self.time = time
        self.name = name
        self.requiresCoordinates = requiresCoordinates
        self.limit = limit
    }
}

/// Which way a traversal follows a directed link.
public enum LinkDirection: String, Codable, Sendable, Hashable {
    /// Follow `from` to `to`.
    case outgoing
    /// Follow `to` back to `from`.
    case incoming
    /// Treat the link as traversable either way.
    case both
}

/// An entity one hop away, plus the link that reached it.
public struct Neighbor: Equatable, Sendable, Hashable {
    public var entity: Entity
    public var link: Link
    /// `.outgoing` when the origin is `link.fromID`. Never `.both`.
    public var direction: LinkDirection

    public init(entity: Entity, link: Link, direction: LinkDirection) {
        self.entity = entity
        self.link = link
        self.direction = direction
    }
}

/// Entities and the links whose endpoints are both in `entities`.
public struct Subgraph: Equatable, Sendable, Hashable {
    public var entities: [Entity]
    public var links: [Link]

    public init(entities: [Entity], links: [Link]) {
        self.entities = entities
        self.links = links
    }
}

/// One simple path, including both endpoints. `links.count` is the hop count.
public struct GraphPath: Equatable, Sendable, Hashable {
    public var entities: [Entity]
    public var links: [Link]

    public init(entities: [Entity], links: [Link]) {
        self.entities = entities
        self.links = links
    }

    public var hopCount: Int { links.count }
}

/// An entity that can be pinned on the globe. Coordinates are always present.
public struct GlobePin: Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: EntityKind
    public var latitude: Double
    public var longitude: Double
    public var occurredAt: Date?
    public var endedAt: Date?

    public init(
        id: String,
        name: String,
        kind: EntityKind,
        latitude: Double,
        longitude: Double,
        occurredAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.occurredAt = occurredAt
        self.endedAt = endedAt
    }

    public var entityID: String { id }
}

/// How many records an upsert or import wrote, after collapsing duplicate ids.
public struct ImportResult: Equatable, Sendable {
    public var entitiesUpserted: Int
    public var linksUpserted: Int

    public init(entitiesUpserted: Int, linksUpserted: Int) {
        self.entitiesUpserted = entitiesUpserted
        self.linksUpserted = linksUpserted
    }
}

enum CodableDate {
    static func decode<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) throws -> Date? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return nil
        }
        if let text = try? container.decode(String.self, forKey: key) {
            guard let date = IntelDate.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unrecognized date \(text)"
                )
            }
            return date
        }
        if let seconds = try? container.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Date was not a string or a number"
        )
    }

    static func encode<Key: CodingKey>(
        _ date: Date?,
        to container: inout KeyedEncodingContainer<Key>,
        key: Key
    ) throws {
        if let date {
            try container.encode(IntelDate.iso8601(date), forKey: key)
        }
    }
}
