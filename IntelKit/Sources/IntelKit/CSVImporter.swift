import Foundation

/// Reads entities and links from CSV text.
///
/// The first row is a header. Names are matched without case, spaces, or
/// underscores, so `source_url` and `sourceURL` are the same column.
///
/// Entity columns: `id`, `kind`, `name`, `latitude` (`lat`), `longitude`
/// (`lon` or `lng`), `occurred_at`, `ended_at`, `source`, `source_url`,
/// `external_id`, `retrieved_at`, `properties_json`. Any other column becomes
/// a string property.
///
/// Link columns: `id`, `type`, `from_id` (`from`), `to_id` (`to`), plus the
/// provenance and `properties_json` columns above. `from` / `to` match an
/// entity id first, then a unique folded name.
///
/// A file that contains `record_type` (`entity` or `link`) can carry both.
/// Entity rows are written before link rows. A file with no `record_type` is
/// treated as links when it has `from` or `to`, and as entities otherwise.
///
/// Dates are ISO-8601 or GDELT `YYYYMMDDThhmmssZ`. When a row omits provenance,
/// the `provenance` argument is used. Re-importing a row with the same id
/// replaces it.
public enum CSVImporter {
    @discardableResult
    public static func importCSV(
        _ csv: String,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        let table = try CSVTable.parse(csv)
        if table.headers.contains("recordtype") {
            return try importMixed(table, into: store, provenance: provenance)
        }
        if table.headers.contains("fromid") || table.headers.contains("toid")
            || table.headers.contains("from") || table.headers.contains("to")
        {
            return try importLinks(table, into: store, provenance: provenance)
        }
        return try importEntities(table, into: store, provenance: provenance)
    }

    @discardableResult
    public static func importEntities(
        _ csv: String,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        try importEntities(try CSVTable.parse(csv), into: store, provenance: provenance)
    }

    @discardableResult
    public static func importLinks(
        _ csv: String,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        try importLinks(try CSVTable.parse(csv), into: store, provenance: provenance)
    }

    private static func importMixed(
        _ table: CSVTable,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        let entities = table.rows.filter { recordKind($0) == .entity }
        let links = table.rows.filter { recordKind($0) == .link }
        let unknown = table.rows.filter { recordKind($0) == nil }
        if let unknown = unknown.first {
            throw IntelError.malformedImport(
                "Row \(unknown.line): record_type must be 'entity' or 'link'"
            )
        }
        let entityResult = try writeEntities(entities, into: store, provenance: provenance)
        let linkResult = try writeLinks(links, into: store, provenance: provenance)
        return ImportResult(
            entitiesUpserted: entityResult.entitiesUpserted,
            linksUpserted: linkResult.linksUpserted
        )
    }

    private static func importEntities(
        _ table: CSVTable,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        try writeEntities(table.rows, into: store, provenance: provenance)
    }

    private static func importLinks(
        _ table: CSVTable,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        try writeLinks(table.rows, into: store, provenance: provenance)
    }

    private static func writeEntities(
        _ rows: [CSVTable.Row],
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        let entities = try rows.map { try entity(from: $0, defaultProvenance: provenance) }
        return try store.upsert(entities: entities, links: [])
    }

    private static func writeLinks(
        _ rows: [CSVTable.Row],
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        let links = try rows.map { try link(from: $0, store: store, defaultProvenance: provenance) }
        return try store.upsert(entities: [], links: links)
    }

    private enum RecordKind {
        case entity
        case link
    }

    private static func recordKind(_ row: CSVTable.Row) -> RecordKind? {
        switch row.value("recordtype")?.intelFolded() {
        case "entity", "entities", "node":
            return .entity
        case "link", "relationship", "edge":
            return .link
        default:
            return nil
        }
    }

    private static func entity(from row: CSVTable.Row, defaultProvenance: Provenance) throws -> Entity {
        let name = try required(row, "name")
        guard let kindToken = row.value("kind") ?? row.value("type"),
            let kind = EntityKind.parse(kindToken)
        else {
            let shown = row.value("kind") ?? row.value("type") ?? ""
            throw IntelError.malformedImport("Row \(row.line): unknown kind '\(shown)'")
        }
        let provenance = try provenance(from: row, fallback: defaultProvenance)
        let id = row.value("id").flatMap { blankToNil($0) }
            ?? StableID.entity(kind: kind, name: name, externalID: provenance.externalID)
        let latitude = try coordinate(row, keys: ["latitude", "lat"])
        let longitude = try coordinate(row, keys: ["longitude", "lon", "lng"])
        return Entity(
            id: id,
            kind: kind,
            name: name,
            properties: try properties(from: row, reserved: entityReserved),
            latitude: latitude,
            longitude: longitude,
            occurredAt: try date(row, keys: ["occurredat", "start"]),
            endedAt: try date(row, keys: ["endedat", "end"]),
            provenance: provenance
        )
    }

    private static func link(
        from row: CSVTable.Row,
        store: IntelStore,
        defaultProvenance: Provenance
    ) throws -> Link {
        let type = try required(row, "type")
        let provenance = try provenance(from: row, fallback: defaultProvenance)
        guard let fromToken = row.value("fromid") ?? row.value("from"), !fromToken.isEmpty else {
            throw IntelError.malformedImport("Row \(row.line): link is missing from_id")
        }
        guard let toToken = row.value("toid") ?? row.value("to"), !toToken.isEmpty else {
            throw IntelError.malformedImport("Row \(row.line): link is missing to_id")
        }
        let fromID = try resolve(fromToken, store: store, line: row.line, end: "from")
        let toID = try resolve(toToken, store: store, line: row.line, end: "to")
        let id = row.value("id").flatMap { blankToNil($0) }
            ?? StableID.link(type: type, fromID: fromID, toID: toID)
        return Link(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: try properties(from: row, reserved: linkReserved),
            provenance: provenance
        )
    }

    private static func resolve(_ token: String, store: IntelStore, line: Int, end: String) throws -> String {
        if try store.entity(id: token) != nil {
            return token
        }
        let matches = try store.entities(exactlyNamed: token)
        if matches.count == 1, let id = matches.first?.id {
            return id
        }
        if matches.count > 1 {
            throw IntelError.malformedImport(
                "Row \(line): \(end) '\(token)' matches \(matches.count) entities; use an id"
            )
        }
        throw IntelError.malformedImport("Row \(line): \(end) '\(token)' does not match an entity")
    }

    private static func provenance(from row: CSVTable.Row, fallback: Provenance) throws -> Provenance {
        let source = blankToNil(row.value("source")) ?? fallback.source
        let retrieved: Date
        if let raw = blankToNil(row.value("retrievedat")) {
            guard let parsed = IntelDate.parse(raw) else {
                throw IntelError.malformedImport("Row \(row.line): unrecognized retrieved_at '\(raw)'")
            }
            retrieved = parsed
        } else {
            retrieved = fallback.retrievedAt
        }
        return Provenance(
            source: source,
            retrievedAt: retrieved,
            sourceURL: blankToNil(row.value("sourceurl")) ?? fallback.sourceURL,
            externalID: blankToNil(row.value("externalid")) ?? fallback.externalID
        )
    }

    private static func properties(from row: CSVTable.Row, reserved: Set<String>) throws -> [String: JSONValue] {
        var properties: [String: JSONValue] = [:]
        if let raw = blankToNil(row.value("propertiesjson") ?? row.value("properties")) {
            guard let data = raw.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw IntelError.malformedImport("Row \(row.line): properties_json is not a JSON object")
            }
            properties = object.mapValues(JSONCodec.value(from:))
        }
        for (key, value) in row.values where !reserved.contains(key) {
            if let text = blankToNil(value) {
                properties[row.labels[key] ?? key] = .string(text)
            }
        }
        return properties
    }

    private static func coordinate(_ row: CSVTable.Row, keys: [String]) throws -> Double? {
        guard let raw = keys.compactMap({ blankToNil(row.value($0)) }).first else {
            return nil
        }
        guard let value = Double(raw) else {
            throw IntelError.malformedImport("Row \(row.line): '\(raw)' is not a number")
        }
        return value
    }

    private static func date(_ row: CSVTable.Row, keys: [String]) throws -> Date? {
        guard let raw = keys.compactMap({ blankToNil(row.value($0)) }).first else {
            return nil
        }
        guard let date = IntelDate.parse(raw) else {
            throw IntelError.malformedImport("Row \(row.line): unrecognized date '\(raw)'")
        }
        return date
    }

    private static func required(_ row: CSVTable.Row, _ key: String) throws -> String {
        guard let value = blankToNil(row.value(key)) else {
            throw IntelError.malformedImport("Row \(row.line): missing \(key)")
        }
        return value
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let entityReserved: Set<String> = [
        "id", "kind", "type", "name", "latitude", "lat", "longitude", "lon", "lng",
        "occurredat", "start", "endedat", "end", "source", "sourceurl", "externalid",
        "retrievedat", "propertiesjson", "properties", "recordtype",
    ]

    private static let linkReserved: Set<String> = [
        "id", "type", "fromid", "from", "toid", "to", "source", "sourceurl",
        "externalid", "retrievedat", "propertiesjson", "properties", "recordtype",
        "kind", "name",
    ]
}

struct CSVTable {
    struct Row {
        var line: Int
        var values: [String: String]
        /// Normalized header key to the header text, so extra columns keep their names.
        var labels: [String: String]

        func value(_ key: String) -> String? {
            values[key]
        }
    }

    var headers: Set<String>
    var rows: [Row]

    static func parse(_ text: String) throws -> CSVTable {
        var source = text
        if source.hasPrefix("\u{feff}") {
            source.removeFirst()
        }
        let records = try records(from: source)
        guard let headerRecord = records.first else {
            throw IntelError.malformedImport("CSV has no header row")
        }
        if headerRecord.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw IntelError.malformedImport("CSV has no header row")
        }
        var headers: [String] = []
        var labels: [String: String] = [:]
        var seen = Set<String>()
        for column in headerRecord {
            let key = HeaderKey.normalize(column)
            if key.isEmpty {
                throw IntelError.malformedImport("CSV header contains an empty column name")
            }
            if !seen.insert(key).inserted {
                throw IntelError.malformedImport("CSV header repeats column \(column)")
            }
            headers.append(key)
            labels[key] = column.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rows: [Row] = []
        for (offset, record) in records.dropFirst().enumerated() {
            let line = offset + 2
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            if record.count != headers.count {
                throw IntelError.malformedImport(
                    "Row \(line) has \(record.count) columns; the header has \(headers.count)"
                )
            }
            var values: [String: String] = [:]
            for (key, value) in zip(headers, record) {
                values[key] = value
            }
            rows.append(Row(line: line, values: values, labels: labels))
        }
        return CSVTable(headers: seen, rows: rows)
    }

    private static func records(from text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldQuoted = false
        var justClosedQuote = false
        var pendingSpaces = ""
        let characters = Array(text)
        var index = 0

        func finishField() {
            if !fieldQuoted {
                field = (pendingSpaces + field).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            record.append(field)
            field = ""
            pendingSpaces = ""
            fieldQuoted = false
            justClosedQuote = false
        }

        func finishRecord() {
            finishField()
            records.append(record)
            record = []
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    justClosedQuote = true
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }
            if character == "," {
                finishField()
                index += 1
                continue
            }
            if character == "\n" || character == "\r" {
                finishRecord()
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if justClosedQuote {
                if character.isWhitespace {
                    index += 1
                    continue
                }
                throw IntelError.malformedImport("CSV has text after a closing quote")
            }
            if character == "\"" {
                if !field.isEmpty || !pendingSpaces.isEmpty {
                    throw IntelError.malformedImport("CSV has a quote after field text")
                }
                inQuotes = true
                fieldQuoted = true
                index += 1
                continue
            }
            if character.isWhitespace, field.isEmpty, !fieldQuoted {
                pendingSpaces.append(character)
            } else {
                field.append(contentsOf: pendingSpaces)
                pendingSpaces = ""
                field.append(character)
            }
            index += 1
        }
        if inQuotes {
            throw IntelError.malformedImport("CSV has an unterminated quote")
        }
        if !field.isEmpty || !pendingSpaces.isEmpty || !record.isEmpty {
            finishRecord()
        }
        return records
    }
}
