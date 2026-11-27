import Foundation

/// Reads entities and links from JSON.
///
/// Three roots are accepted:
///
/// - An object with `entities` and/or `links` arrays.
/// - An array of entity objects.
/// - One entity object (`kind` and `name`).
///
/// Keys may be camelCase or snake_case (`from_id`, `occurred_at`, `source_url`).
/// Dates are ISO-8601 strings, GDELT `YYYYMMDDThhmmssZ` stamps, or Unix seconds.
/// A record that omits provenance uses the `provenance` argument. A record that
/// omits `id` gets a stable id from its kind, name, and external id, so importing
/// the same file again updates rows instead of duplicating them.
public enum JSONImporter {
    @discardableResult
    public static func importJSON(
        _ data: Data,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        let root: Any
        do {
            guard !data.isEmpty else {
                throw IntelError.malformedImport("JSON import was empty")
            }
            root = try JSONSerialization.jsonObject(with: data)
        } catch let error as IntelError {
            throw error
        } catch {
            throw IntelError.malformedImport("JSON import could not be read")
        }
        return try importRoot(root, into: store, provenance: provenance)
    }

    @discardableResult
    public static func importJSON(
        _ string: String,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        guard let data = string.data(using: .utf8) else {
            throw IntelError.malformedImport("JSON import was not UTF-8")
        }
        return try importJSON(data, into: store, provenance: provenance)
    }

    private static func importRoot(
        _ root: Any,
        into store: IntelStore,
        provenance: Provenance
    ) throws -> ImportResult {
        if let array = root as? [Any] {
            let entities = try array.enumerated().map { index, value in
                try entity(from: object(value, label: "entity \(index + 1)"), fallback: provenance)
            }
            return try store.upsert(entities: entities, links: [])
        }
        let document = try object(root, label: "root")
        if document["entities"] != nil || document["links"] != nil {
            let entityValues = document["entities"] as? [Any] ?? []
            if document["entities"] != nil, document["entities"] as? [Any] == nil {
                throw IntelError.malformedImport("'entities' must be an array")
            }
            let linkValues = document["links"] as? [Any] ?? []
            if document["links"] != nil, document["links"] as? [Any] == nil {
                throw IntelError.malformedImport("'links' must be an array")
            }
            let entities = try entityValues.enumerated().map { index, value in
                try entity(from: object(value, label: "entities[\(index)]"), fallback: provenance)
            }
            let links = try linkValues.enumerated().map { index, value in
                try link(from: object(value, label: "links[\(index)]"), fallback: provenance)
            }
            return try store.upsert(entities: entities, links: links)
        }
        let single = try entity(from: document, fallback: provenance)
        return try store.upsert(entities: [single], links: [])
    }

    private static func entity(from object: [String: Any], fallback: Provenance) throws -> Entity {
        let name = try requiredString(object, "name")
        let kindToken = try requiredString(object, "kind")
        guard let kind = EntityKind.parse(kindToken) else {
            throw IntelError.malformedImport("Unknown kind '\(kindToken)'")
        }
        let provenance = try provenance(from: object, fallback: fallback)
        let id = string(object, "id")
            ?? StableID.entity(kind: kind, name: name, externalID: provenance.externalID)
        return Entity(
            id: id,
            kind: kind,
            name: name,
            properties: try properties(object),
            latitude: number(object, "latitude") ?? number(object, "lat"),
            longitude: number(object, "longitude") ?? number(object, "lon") ?? number(object, "lng"),
            occurredAt: try date(object, "occurredat", "occurred_at"),
            endedAt: try date(object, "endedat", "ended_at"),
            provenance: provenance
        )
    }

    private static func link(from object: [String: Any], fallback: Provenance) throws -> Link {
        let type = try requiredString(object, "type")
        guard let fromID = string(object, "fromid", "from_id", "from") else {
            throw IntelError.malformedImport("Link is missing fromID")
        }
        guard let toID = string(object, "toid", "to_id", "to") else {
            throw IntelError.malformedImport("Link is missing toID")
        }
        let provenance = try provenance(from: object, fallback: fallback)
        let id = string(object, "id") ?? StableID.link(type: type, fromID: fromID, toID: toID)
        return Link(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: try properties(object),
            provenance: provenance
        )
    }

    private static func provenance(from object: [String: Any], fallback: Provenance) throws -> Provenance {
        let nested: [String: Any]
        if let raw = object["provenance"] as? [String: Any] {
            nested = try self.object(raw, label: "provenance")
        } else if object["provenance"] != nil, !(object["provenance"] is NSNull) {
            throw IntelError.malformedImport("provenance must be an object")
        } else {
            nested = [:]
        }
        let source = string(nested, "source") ?? string(object, "source") ?? fallback.source
        let retrieved = try date(nested, "retrievedat")
            ?? (try date(object, "retrievedat"))
            ?? fallback.retrievedAt
        return Provenance(
            source: source,
            retrievedAt: retrieved,
            sourceURL: string(nested, "sourceurl", "source_url")
                ?? string(object, "sourceurl", "source_url")
                ?? fallback.sourceURL,
            externalID: string(nested, "externalid", "external_id")
                ?? string(object, "externalid", "external_id")
                ?? fallback.externalID
        )
    }

    private static func properties(_ object: [String: Any]) throws -> [String: JSONValue] {
        guard let raw = object["properties"], !(raw is NSNull) else {
            return [:]
        }
        guard let dictionary = raw as? [String: Any] else {
            throw IntelError.malformedImport("properties must be an object")
        }
        return dictionary.mapValues(JSONCodec.value(from:))
    }

    private static func object(_ value: Any, label: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw IntelError.malformedImport("\(label) must be an object")
        }
        var normalized: [String: Any] = [:]
        for (key, value) in object {
            normalized[HeaderKey.normalize(key)] = value
        }
        return normalized
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            let normalized = HeaderKey.normalize(key)
            if let value = object[normalized] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func requiredString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = string(object, key) else {
            throw IntelError.malformedImport("Missing \(key)")
        }
        return value
    }

    private static func number(_ object: [String: Any], _ key: String) -> Double? {
        let value = object[HeaderKey.normalize(key)]
        if let number = value as? NSNumber, !(value is Bool) {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func date(_ object: [String: Any], _ keys: String...) throws -> Date? {
        for key in keys {
            let normalized = HeaderKey.normalize(key)
            guard object[normalized] != nil, !(object[normalized] is NSNull) else {
                continue
            }
            let value = object[normalized]
            if let text = value as? String {
                guard let date = IntelDate.parse(text) else {
                    throw IntelError.malformedImport("Unrecognized date '\(text)'")
                }
                return date
            }
            if let number = value as? NSNumber, !(value is Bool) {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            throw IntelError.malformedImport("Date \(key) was not a string or a number")
        }
        return nil
    }
}
