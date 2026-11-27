import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How far back a GDELT query looks when no absolute start and end are set.
///
/// The raw value is GDELT's own token (`24h`, `7d`, `4w`, `1m`).
public struct GDELTTimespan: Equatable, Sendable, Hashable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func hours(_ count: Int) -> GDELTTimespan {
        GDELTTimespan(rawValue: "\(max(count, 1))h")
    }

    public static func days(_ count: Int) -> GDELTTimespan {
        GDELTTimespan(rawValue: "\(max(count, 1))d")
    }

    public static func weeks(_ count: Int) -> GDELTTimespan {
        GDELTTimespan(rawValue: "\(max(count, 1))w")
    }

    public static func months(_ count: Int) -> GDELTTimespan {
        GDELTTimespan(rawValue: "\(max(count, 1))m")
    }
}

/// A keyless GDELT DOC or GEO search.
///
/// When both `start` and `end` are set they are sent as `startdatetime` and
/// `enddatetime`, and `timespan` is omitted. Otherwise `timespan` is sent.
public struct GDELTQuery: Equatable, Sendable {
    public var text: String
    public var timespan: GDELTTimespan?
    public var start: Date?
    public var end: Date?
    public var maxRecords: Int
    /// GDELT `sourcelang`, for example `english`. Nil searches every language.
    public var sourceLanguage: String?

    public init(
        text: String,
        timespan: GDELTTimespan? = .days(1),
        start: Date? = nil,
        end: Date? = nil,
        maxRecords: Int = 25,
        sourceLanguage: String? = nil
    ) {
        self.text = text
        self.timespan = timespan
        self.start = start
        self.end = end
        self.maxRecords = maxRecords
        self.sourceLanguage = sourceLanguage
    }

    var clampedMaxRecords: Int {
        min(max(maxRecords, 1), 250)
    }
}

/// One article from the DOC 2.0 `artlist` mode.
public struct GDELTArticle: Equatable, Sendable {
    public var url: String
    public var mobileURL: String?
    public var title: String
    public var seenAt: Date?
    public var socialImage: String?
    public var domain: String
    public var language: String
    public var sourceCountry: String

    public init(
        url: String,
        mobileURL: String? = nil,
        title: String,
        seenAt: Date? = nil,
        socialImage: String? = nil,
        domain: String,
        language: String,
        sourceCountry: String
    ) {
        self.url = url
        self.mobileURL = mobileURL
        self.title = title
        self.seenAt = seenAt
        self.socialImage = socialImage
        self.domain = domain
        self.language = language
        self.sourceCountry = sourceCountry
    }
}

/// One bucket of a DOC timeline. `norm` is the total articles GDELT monitored
/// in that bucket, and is only present for `timelinevolraw`.
public struct GDELTTimelineBucket: Equatable, Sendable {
    public var date: Date
    public var value: Double
    public var norm: Double?

    public init(date: Date, value: Double, norm: Double? = nil) {
        self.date = date
        self.value = value
        self.norm = norm
    }
}

/// A named series from a DOC timeline response.
public struct GDELTTimelineSeries: Equatable, Sendable {
    public var name: String
    public var buckets: [GDELTTimelineBucket]

    public init(name: String, buckets: [GDELTTimelineBucket]) {
        self.name = name
        self.buckets = buckets
    }
}

/// An article mentioned in a GEO point's popup HTML.
public struct GDELTGeoArticle: Equatable, Sendable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

/// A location from the GEO 2.0 `PointData` mode. Coordinates are decimal degrees.
public struct GDELTGeoPoint: Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var count: Int
    public var articles: [GDELTGeoArticle]

    public init(
        name: String,
        latitude: Double,
        longitude: Double,
        count: Int,
        articles: [GDELTGeoArticle] = []
    ) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.count = count
        self.articles = articles
    }
}

/// Controls how a GDELT payload is written into the store.
public struct GDELTImportOptions: Equatable, Sendable {
    /// When true, a timeless event named with the query text is linked to
    /// every imported event and place, so expansion from that hub reaches them.
    public var createQueryHub: Bool

    public init(createQueryHub: Bool = true) {
        self.createQueryHub = createQueryHub
    }
}

/// Counts from one ``GDELTClient/importCoverage(_:into:retrievedAt:options:)`` call.
public struct GDELTImportResult: Equatable, Sendable {
    public var articles: Int
    public var geoPoints: Int
    public var entitiesUpserted: Int
    public var linksUpserted: Int

    public init(articles: Int, geoPoints: Int, entitiesUpserted: Int, linksUpserted: Int) {
        self.articles = articles
        self.geoPoints = geoPoints
        self.entitiesUpserted = entitiesUpserted
        self.linksUpserted = linksUpserted
    }
}

/// Fetches bytes for a GDELT URL. Tests supply a fixture transport; the app uses
/// ``URLSessionGDELTTransport``.
public protocol GDELTTransport: Sendable {
    func data(for url: URL) async throws -> Data
}

/// `URLSession` transport. Sends a user agent because GDELT rejects empty ones.
public struct URLSessionGDELTTransport: GDELTTransport {
    public let session: URLSession
    public let userAgent: String
    public let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        userAgent: String = "GodsEyeView-IntelKit/1.0",
        timeout: TimeInterval = 30
    ) {
        self.session = session
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntelError.gdelt("GDELT response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IntelError.gdelt(
                "GDELT answered HTTP \(http.statusCode): \(GDELTDecoder.snippet(body))"
            )
        }
        return body
    }
}

/// DOC 2.0 and GEO 2.0 client. No API key. Nothing is stored until
/// ``importCoverage(_:into:retrievedAt:options:)`` is called.
///
/// DOC `artlist` does not name the people in a story. Publishing outlets become
/// organization actors (`reported_by`). The outlet's source country becomes a
/// place (`based_in`). GEO `PointData` becomes places with coordinates, and
/// articles parsed out of each point's popup are events `occurred_in` that place.
/// The same article URL from DOC and GEO collapses to one event.
public struct GDELTClient: Sendable {
    private let transport: any GDELTTransport

    public init(transport: any GDELTTransport = URLSessionGDELTTransport()) {
        self.transport = transport
    }

    public func articles(matching query: GDELTQuery) async throws -> [GDELTArticle] {
        let url = try Self.endpoint(
            base: Self.docBase,
            query: query,
            mode: "artlist",
            format: "json",
            recordParameter: "maxrecords",
            sort: true
        )
        return try GDELTDecoder.articles(from: try await transport.data(for: url))
    }

    /// DOC `timelinevolraw`: article counts per bucket, with the `norm` total.
    public func timeline(matching query: GDELTQuery) async throws -> [GDELTTimelineSeries] {
        let url = try Self.endpoint(
            base: Self.docBase,
            query: query,
            mode: "timelinevolraw",
            format: "json",
            recordParameter: "maxrecords",
            sort: false
        )
        return try GDELTDecoder.timeline(from: try await transport.data(for: url))
    }

    /// GEO `PointData` as GeoJSON points.
    public func geoPoints(matching query: GDELTQuery) async throws -> [GDELTGeoPoint] {
        let url = try Self.endpoint(
            base: Self.geoBase,
            query: query,
            mode: "PointData",
            format: "geojson",
            recordParameter: "maxpoints",
            sort: false
        )
        return try GDELTDecoder.geoPoints(from: try await transport.data(for: url))
    }

    /// Fetches articles and geo points, then upserts the mapped graph.
    ///
    /// The two requests run together. GDELT asks callers to stay near one
    /// request every few seconds; a burst of imports can come back as plain
    /// text, which the decoder reports as ``IntelError/gdelt(_:)``.
    @discardableResult
    public func importCoverage(
        _ query: GDELTQuery,
        into store: IntelStore,
        retrievedAt: Date = Date(),
        options: GDELTImportOptions = GDELTImportOptions()
    ) async throws -> GDELTImportResult {
        let articleURL = try Self.endpoint(
            base: Self.docBase,
            query: query,
            mode: "artlist",
            format: "json",
            recordParameter: "maxrecords",
            sort: true
        )
        let geoURL = try Self.endpoint(
            base: Self.geoBase,
            query: query,
            mode: "PointData",
            format: "geojson",
            recordParameter: "maxpoints",
            sort: false
        )
        async let articleBody = transport.data(for: articleURL)
        async let geoBody = transport.data(for: geoURL)
        let articles = try GDELTDecoder.articles(from: try await articleBody)
        let points = try GDELTDecoder.geoPoints(from: try await geoBody)
        let mapped = GDELTMapper.graph(
            articles: articles,
            geoPoints: points,
            query: query.text,
            retrievedAt: retrievedAt,
            options: options
        )
        let written = try store.upsert(entities: mapped.entities, links: mapped.links)
        return GDELTImportResult(
            articles: articles.count,
            geoPoints: points.count,
            entitiesUpserted: written.entitiesUpserted,
            linksUpserted: written.linksUpserted
        )
    }

    static let docBase = URL(string: "https://api.gdeltproject.org/api/v2/doc/doc")!
    static let geoBase = URL(string: "https://api.gdeltproject.org/api/v2/geo/geo")!

    static func endpoint(
        base: URL,
        query: GDELTQuery,
        mode: String,
        format: String,
        recordParameter: String,
        sort: Bool
    ) throws -> URL {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw IntelError.validation("GDELT query text is empty")
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw IntelError.gdelt("Could not build a GDELT URL")
        }
        var items = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: recordParameter, value: String(query.clampedMaxRecords)),
        ]
        if let start = query.start, let end = query.end {
            items.append(URLQueryItem(name: "startdatetime", value: IntelDate.gdeltTimestamp(start)))
            items.append(URLQueryItem(name: "enddatetime", value: IntelDate.gdeltTimestamp(end)))
        } else if let timespan = query.timespan {
            items.append(URLQueryItem(name: "timespan", value: timespan.rawValue))
        }
        if let language = query.sourceLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
            !language.isEmpty
        {
            items.append(URLQueryItem(name: "sourcelang", value: language))
        }
        if sort {
            items.append(URLQueryItem(name: "sort", value: "datedesc"))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw IntelError.gdelt("Could not build a GDELT URL")
        }
        return url
    }
}

/// Parses GDELT JSON. Network-free, so tests can pass fixtures straight in.
public enum GDELTDecoder {
    public static func articles(from data: Data) throws -> [GDELTArticle] {
        let root = try jsonObject(data)
        guard let raw = root["articles"] else {
            return []
        }
        if raw is NSNull {
            return []
        }
        guard let articles = raw as? [Any] else {
            throw IntelError.gdelt("GDELT artlist 'articles' was not an array")
        }
        var parsed: [GDELTArticle] = []
        for value in articles {
            guard let object = value as? [String: Any] else {
                throw IntelError.gdelt("GDELT artlist contained a non-object article")
            }
            guard let url = string(object, "url"), !url.isEmpty else {
                continue
            }
            let seen = string(object, "seendate").flatMap(IntelDate.parse)
            parsed.append(
                GDELTArticle(
                    url: url,
                    mobileURL: emptyToNil(string(object, "url_mobile")),
                    title: string(object, "title") ?? "",
                    seenAt: seen,
                    socialImage: emptyToNil(string(object, "socialimage")),
                    domain: string(object, "domain") ?? "",
                    language: string(object, "language") ?? "",
                    sourceCountry: string(object, "sourcecountry") ?? ""
                )
            )
        }
        return parsed
    }

    public static func timeline(from data: Data) throws -> [GDELTTimelineSeries] {
        let root = try jsonObject(data)
        guard let raw = root["timeline"] else {
            return []
        }
        if raw is NSNull {
            return []
        }
        guard let timeline = raw as? [Any] else {
            throw IntelError.gdelt("GDELT timeline was not an array")
        }
        if timeline.isEmpty {
            return []
        }
        if timeline.allSatisfy(isBucket) {
            return [GDELTTimelineSeries(name: "Volume", buckets: try buckets(from: timeline))]
        }
        var series: [GDELTTimelineSeries] = []
        for value in timeline {
            guard let object = value as? [String: Any] else {
                throw IntelError.gdelt("GDELT timeline series was not an object")
            }
            let name = string(object, "series") ?? "Volume"
            let data = object["data"] as? [Any] ?? []
            if object["data"] != nil, object["data"] as? [Any] == nil, !(object["data"] is NSNull) {
                throw IntelError.gdelt("GDELT timeline series data was not an array")
            }
            series.append(GDELTTimelineSeries(name: name, buckets: try buckets(from: data)))
        }
        return series
    }

    public static func geoPoints(from data: Data) throws -> [GDELTGeoPoint] {
        let root = try jsonObject(data)
        guard let raw = root["features"] else {
            throw IntelError.gdelt("GDELT GEO JSON had no features")
        }
        if raw is NSNull {
            return []
        }
        guard let features = raw as? [Any] else {
            throw IntelError.gdelt("GDELT GEO features were not an array")
        }
        var points: [GDELTGeoPoint] = []
        for value in features {
            guard let feature = value as? [String: Any] else {
                continue
            }
            guard let geometry = feature["geometry"] as? [String: Any] else {
                continue
            }
            let geometryType = (string(geometry, "type") ?? "").lowercased()
            guard geometryType == "point" else {
                continue
            }
            guard
                let coordinates = geometry["coordinates"] as? [Any],
                coordinates.count >= 2,
                let longitude = doubleValue(coordinates[0]),
                let latitude = doubleValue(coordinates[1]),
                latitude.isFinite, longitude.isFinite,
                (-90...90).contains(latitude),
                (-180...180).contains(longitude)
            else {
                continue
            }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let name = string(properties, "name") ?? String(format: "%.4f, %.4f", latitude, longitude)
            let count = Int(doubleValue(properties["count"]) ?? 1)
            let html = string(properties, "html") ?? ""
            let articles = HTMLText.anchorArticles(in: html).map { article in
                GDELTGeoArticle(url: article.url, title: article.title)
            }
            points.append(
                GDELTGeoPoint(
                    name: name,
                    latitude: latitude,
                    longitude: longitude,
                    count: max(count, 0),
                    articles: articles
                )
            )
        }
        return points
    }

    static func snippet(_ data: Data) -> String {
        let text = String(data: data.prefix(180), encoding: .utf8) ?? ""
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        if data.isEmpty {
            throw IntelError.gdelt("GDELT returned an empty body")
        }
        let first = data.first { byte in
            byte != UInt8(ascii: " ") && byte != UInt8(ascii: "\n")
                && byte != UInt8(ascii: "\r") && byte != UInt8(ascii: "\t")
        }
        if first != UInt8(ascii: "{"), first != UInt8(ascii: "[") {
            throw IntelError.gdelt("GDELT did not return JSON: \(snippet(data))")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw IntelError.gdelt("GDELT JSON root was not an object")
            }
            return dictionary
        } catch let error as IntelError {
            throw error
        } catch {
            throw IntelError.gdelt("GDELT JSON could not be read: \(snippet(data))")
        }
    }

    private static func buckets(from values: [Any]) throws -> [GDELTTimelineBucket] {
        var buckets: [GDELTTimelineBucket] = []
        for value in values {
            guard let object = value as? [String: Any] else {
                throw IntelError.gdelt("GDELT timeline bucket was not an object")
            }
            guard let rawDate = string(object, "date"), let date = IntelDate.parse(rawDate) else {
                throw IntelError.gdelt("GDELT timeline bucket had no date")
            }
            guard let amount = doubleValue(object["value"]) else {
                throw IntelError.gdelt("GDELT timeline bucket had no value")
            }
            buckets.append(
                GDELTTimelineBucket(date: date, value: amount, norm: doubleValue(object["norm"]))
            )
        }
        return buckets
    }

    private static func isBucket(_ value: Any) -> Bool {
        guard let object = value as? [String: Any] else {
            return false
        }
        return object["date"] != nil && object["data"] == nil
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let value = object[key] as? NSNumber, !(object[key] is Bool) {
            return value.stringValue
        }
        return nil
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull), !(value is Bool) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

/// Turns parsed GDELT records into entities and links, without touching the store.
public enum GDELTMapper {
    public static func graph(
        articles: [GDELTArticle],
        geoPoints: [GDELTGeoPoint],
        query: String?,
        retrievedAt: Date,
        options: GDELTImportOptions = GDELTImportOptions()
    ) -> (entities: [Entity], links: [Link]) {
        var entities: [String: Entity] = [:]
        var links: [String: Link] = [:]

        func addEntity(_ entity: Entity) {
            if let existing = entities[entity.id] {
                entities[entity.id] = existing.fillingGaps(from: entity)
            } else {
                entities[entity.id] = entity
            }
        }

        func addLink(_ link: Link) {
            links[link.id] = link
        }

        for article in articles {
            let eventID = StableID.gdeltArticle(article.url)
            var properties: [String: JSONValue] = [
                "url": .string(article.url),
                "gdeltRecord": .string("article"),
            ]
            if !article.domain.isEmpty {
                properties["domain"] = .string(article.domain)
            }
            if !article.language.isEmpty {
                properties["language"] = .string(article.language)
            }
            if !article.sourceCountry.isEmpty {
                properties["sourceCountry"] = .string(article.sourceCountry)
            }
            if let socialImage = article.socialImage, !socialImage.isEmpty {
                properties["socialImage"] = .string(socialImage)
            }
            let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let event = Entity(
                id: eventID,
                kind: .event,
                name: title.isEmpty ? article.url : title,
                properties: properties,
                occurredAt: article.seenAt,
                provenance: Provenance(
                    source: "GDELT DOC",
                    retrievedAt: retrievedAt,
                    sourceURL: article.url,
                    externalID: article.url
                )
            )
            addEntity(event)

            if !article.domain.isEmpty {
                let actorID = StableID.gdeltActor(domain: article.domain)
                addEntity(
                    Entity(
                        id: actorID,
                        kind: .organization,
                        name: article.domain,
                        properties: [
                            "role": .string("publisher"),
                            "actor": .bool(true),
                            "domain": .string(article.domain),
                        ],
                        provenance: Provenance(
                            source: "GDELT DOC",
                            retrievedAt: retrievedAt,
                            externalID: article.domain
                        )
                    )
                )
                addLink(
                    Link(
                        id: StableID.gdeltLink(from: eventID, type: LinkType.reportedBy, to: actorID),
                        type: LinkType.reportedBy,
                        fromID: eventID,
                        toID: actorID,
                        provenance: event.provenance
                    )
                )
                if !article.sourceCountry.isEmpty {
                    let countryID = StableID.gdeltPlace(name: article.sourceCountry)
                    addEntity(
                        Entity(
                            id: countryID,
                            kind: .place,
                            name: article.sourceCountry,
                            properties: ["role": .string("source_country")],
                            provenance: Provenance(
                                source: "GDELT DOC",
                                retrievedAt: retrievedAt,
                                externalID: article.sourceCountry
                            )
                        )
                    )
                    addLink(
                        Link(
                            id: StableID.gdeltLink(from: actorID, type: LinkType.basedIn, to: countryID),
                            type: LinkType.basedIn,
                            fromID: actorID,
                            toID: countryID,
                            provenance: event.provenance
                        )
                    )
                }
            }
        }

        for point in geoPoints {
            let place = Entity(
                id: StableID.gdeltPlace(name: point.name),
                kind: .place,
                name: point.name,
                properties: [
                    "mentionCount": .number(Double(point.count)),
                    "gdeltRecord": .string("geo_point"),
                ],
                latitude: point.latitude,
                longitude: point.longitude,
                provenance: Provenance(
                    source: "GDELT GEO",
                    retrievedAt: retrievedAt,
                    externalID: point.name
                )
            )
            addEntity(place)
            for article in point.articles {
                let eventID = StableID.gdeltArticle(article.url)
                addEntity(
                    Entity(
                        id: eventID,
                        kind: .event,
                        name: article.title,
                        properties: [
                            "url": .string(article.url),
                            "gdeltRecord": .string("article"),
                        ],
                        provenance: Provenance(
                            source: "GDELT GEO",
                            retrievedAt: retrievedAt,
                            sourceURL: article.url,
                            externalID: article.url
                        )
                    )
                )
                addLink(
                    Link(
                        id: StableID.gdeltLink(from: eventID, type: LinkType.occurredIn, to: place.id),
                        type: LinkType.occurredIn,
                        fromID: eventID,
                        toID: place.id,
                        provenance: Provenance(
                            source: "GDELT GEO",
                            retrievedAt: retrievedAt,
                            sourceURL: article.url
                        )
                    )
                )
            }
        }

        if options.createQueryHub,
            let query,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let hub = Entity(
                id: StableID.gdeltQueryHub(query),
                kind: .event,
                name: query.trimmingCharacters(in: .whitespacesAndNewlines),
                properties: [
                    "role": .string("gdelt_query"),
                    "gdeltQuery": .string(query),
                ],
                provenance: Provenance(
                    source: "GDELT",
                    retrievedAt: retrievedAt,
                    externalID: query
                )
            )
            let targets = entities.values.filter { entity in
                entity.id != hub.id && (entity.kind == .event || entity.kind == .place)
            }
            addEntity(hub)
            for target in targets {
                addLink(
                    Link(
                        id: StableID.gdeltLink(from: hub.id, type: LinkType.mentions, to: target.id),
                        type: LinkType.mentions,
                        fromID: hub.id,
                        toID: target.id,
                        provenance: hub.provenance
                    )
                )
            }
        }

        return (
            entities.values.sorted { $0.id < $1.id },
            links.values.sorted { $0.id < $1.id }
        )
    }
}
