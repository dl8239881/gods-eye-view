import XCTest
@testable import IntelKit

final class GDELTTests: XCTestCase {
    func testArtlistParsesSeenDatesAndSkipsNothingWellFormed() throws {
        let articles = try GDELTDecoder.articles(from: try Fixture.data("gdelt-artlist.json"))
        XCTAssertEqual(articles.count, 2)
        XCTAssertEqual(articles[0].title, "Ships reroute around the Red Sea")
        XCTAssertEqual(articles[0].domain, "reuters.com")
        XCTAssertEqual(articles[0].sourceCountry, "United Kingdom")
        XCTAssertEqual(articles[0].mobileURL, "https://www.reuters.com/world/red-sea-2024?mobile")
        XCTAssertUTC(articles[0].seenAt, 2024, 11, 15, 15, 30, 0)
        XCTAssertEqual(articles[1].title, "")
        XCTAssertUTC(articles[1].seenAt, 2024, 11, 15, 12, 0, 0)
        XCTAssertNil(articles[1].socialImage)

        let empty = try GDELTDecoder.articles(from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
        let nullArticles = try GDELTDecoder.articles(from: Data("{\"articles\":null}".utf8))
        XCTAssertTrue(nullArticles.isEmpty)
    }

    func testTimelineParsesSeriesNormAndAFlatList() throws {
        let series = try GDELTDecoder.timeline(from: try Fixture.data("gdelt-timeline.json"))
        XCTAssertEqual(series.map(\.name), ["Volume Intensity", "All Articles"])
        XCTAssertEqual(series[0].buckets.count, 2)
        XCTAssertEqual(series[0].buckets[0].value, 12)
        XCTAssertEqual(series[0].buckets[0].norm, 4000)
        XCTAssertEqual(series[0].buckets[1].value, 3)
        XCTAssertEqual(series[0].buckets[1].norm, 100.5)
        XCTAssertUTC(series[0].buckets[0].date, 2024, 11, 15, 15, 0, 0)
        XCTAssertNil(series[1].buckets[0].norm)

        let flat = """
        {"timeline":[{"date":"20241115T150000Z","value":2}]}
        """.data(using: .utf8)!
        let parsed = try GDELTDecoder.timeline(from: flat)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "Volume")
        XCTAssertEqual(parsed[0].buckets[0].value, 2)
    }

    func testGeoJSONPointsAreLonLatAndHTMLBecomesArticles() throws {
        let points = try GDELTDecoder.geoPoints(from: try Fixture.data("gdelt-geo.json"))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].name, "Aden, Yemen")
        XCTAssertEqual(points[0].longitude, 45.03)
        XCTAssertEqual(points[0].latitude, 12.8)
        XCTAssertEqual(points[0].count, 4)
        XCTAssertEqual(points[0].articles.map(\.url), [
            "https://www.reuters.com/world/red-sea-2024",
            "https://example.net/aden",
        ])
        XCTAssertEqual(points[0].articles[0].title, "Ships & boats reroute")
        XCTAssertEqual(points[0].articles[1].title, "Port of Aden")
    }

    func testPlainTextBodiesAreRejected() throws {
        XCTAssertThrowsError(try GDELTDecoder.articles(from: Data("Please limit requests".utf8))) { error in
            guard case IntelError.gdelt(let message) = error else {
                return XCTFail("Expected gdelt, got \(error)")
            }
            XCTAssertTrue(message.contains("Please limit requests"))
        }
    }

    func testMappingBuildsEventsPlacesAndActors() throws {
        let articles = try GDELTDecoder.articles(from: try Fixture.data("gdelt-artlist.json"))
        let points = try GDELTDecoder.geoPoints(from: try Fixture.data("gdelt-geo.json"))
        let retrieved = utcDate(2024, 11, 16, 8)
        let mapped = GDELTMapper.graph(
            articles: articles,
            geoPoints: points,
            query: "Red Sea",
            retrievedAt: retrieved
        )
        let store = try IntelStore.inMemory()
        _ = try store.upsert(entities: mapped.entities, links: mapped.links)

        let reutersEvents = try store.search(name: "Ships reroute around the Red Sea", kinds: [.event])
        let event = try XCTUnwrap(reutersEvents.first)
        XCTAssertUTC(event.occurredAt, 2024, 11, 15, 15, 30, 0)
        XCTAssertEqual(event.provenance.source, "GDELT DOC")
        XCTAssertEqual(event.properties["url"]?.string, "https://www.reuters.com/world/red-sea-2024")

        let neighbors = try store.neighbors(of: event.id, direction: .outgoing)
        XCTAssertTrue(neighbors.contains { $0.entity.kind == .organization && $0.entity.name == "reuters.com" && $0.link.type == LinkType.reportedBy })
        XCTAssertEqual(neighbors.first { $0.entity.name == "reuters.com" }?.entity.properties["actor"]?.bool, true)
        XCTAssertTrue(neighbors.contains { $0.entity.name == "Aden, Yemen" && $0.link.type == LinkType.occurredIn })

        let aden = try XCTUnwrap(try store.entities(exactlyNamed: "Aden, Yemen").first)
        XCTAssertEqual(aden.latitude, 12.8)
        XCTAssertEqual(aden.longitude, 45.03)
        XCTAssertEqual(aden.properties["mentionCount"]?.number, 4)

        let outlet = try XCTUnwrap(try store.entities(exactlyNamed: "reuters.com").first)
        let based = try store.neighbors(of: outlet.id, direction: .outgoing)
        XCTAssertTrue(based.contains { $0.entity.name == "United Kingdom" && $0.link.type == LinkType.basedIn })
        XCTAssertNil(based.first { $0.entity.name == "United Kingdom" }?.entity.latitude)

        let adenOnly = try store.search(name: "Port of Aden", kinds: [.event])
        XCTAssertEqual(adenOnly.first?.provenance.source, "GDELT GEO")
        let untitled = try store.entities(exactlyNamed: "https://example.com/empty-title")
        XCTAssertEqual(untitled.count, 1)

        let hub = try XCTUnwrap(try store.entities(exactlyNamed: "Red Sea").first)
        XCTAssertNil(hub.occurredAt)
        XCTAssertEqual(hub.properties["role"]?.string, "gdelt_query")
        let fromHub = try store.expand(from: hub.id, hops: 2)
        XCTAssertTrue(fromHub.entities.contains { $0.name == "reuters.com" })

        let pins = try store.globePins()
        XCTAssertTrue(pins.contains { $0.name == "Aden, Yemen" })

        let second = try store.upsert(entities: mapped.entities, links: mapped.links)
        XCTAssertEqual(try store.entityCount(), second.entitiesUpserted)
        XCTAssertEqual(try store.linkCount(), second.linksUpserted)
    }

    func testClientBuildsKeylessURLsAndImportsFixtures() async throws {
        let transport = FixtureTransport(
            payloads: [
                "artlist": try Fixture.data("gdelt-artlist.json"),
                "timelinevolraw": try Fixture.data("gdelt-timeline.json"),
                "PointData": try Fixture.data("gdelt-geo.json"),
            ]
        )
        let client = GDELTClient(transport: transport)
        let query = GDELTQuery(text: "Red Sea", timespan: .hours(24), maxRecords: 10, sourceLanguage: "english")

        let articles = try await client.articles(matching: query)
        XCTAssertEqual(articles.count, 2)
        let timeline = try await client.timeline(matching: query)
        XCTAssertEqual(timeline.count, 2)
        let points = try await client.geoPoints(matching: query)
        XCTAssertEqual(points.count, 1)

        let seen = await transport.urls()
        let articleURL = try XCTUnwrap(seen.first { $0.path.contains("/doc/doc") && mode(of: $0) == "artlist" })
        let items = queryItems(articleURL)
        XCTAssertEqual(articleURL.host, "api.gdeltproject.org")
        XCTAssertEqual(items["query"], "Red Sea")
        XCTAssertEqual(items["format"], "json")
        XCTAssertEqual(items["maxrecords"], "10")
        XCTAssertEqual(items["timespan"], "24h")
        XCTAssertEqual(items["sort"], "datedesc")
        XCTAssertEqual(items["sourcelang"], "english")

        let timelineURL = try XCTUnwrap(seen.first { mode(of: $0) == "timelinevolraw" })
        XCTAssertEqual(queryItems(timelineURL)["format"], "json")
        XCTAssertNil(queryItems(timelineURL)["sort"])

        let geoURL = try XCTUnwrap(seen.first { $0.path.contains("/geo/geo") })
        XCTAssertEqual(mode(of: geoURL), "PointData")
        XCTAssertEqual(queryItems(geoURL)["format"], "geojson")
        XCTAssertEqual(queryItems(geoURL)["maxpoints"], "10")

        let store = try IntelStore.inMemory()
        let imported = try await client.importCoverage(query, into: store, retrievedAt: utcDate(2024, 11, 16))
        XCTAssertEqual(imported.articles, 2)
        XCTAssertEqual(imported.geoPoints, 1)
        XCTAssertGreaterThan(imported.entitiesUpserted, 0)
        XCTAssertEqual(try store.entities(exactlyNamed: "Aden, Yemen").count, 1)

        let bounded = GDELTQuery(
            text: "Red Sea",
            timespan: .days(7),
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3600),
            maxRecords: 500
        )
        _ = try await client.articles(matching: bounded)
        let boundedSeen = await transport.urls()
        let boundedURL = try XCTUnwrap(boundedSeen.last)
        let boundedItems = queryItems(boundedURL)
        XCTAssertEqual(boundedItems["startdatetime"], "19700101000000")
        XCTAssertEqual(boundedItems["enddatetime"], "19700101010000")
        XCTAssertNil(boundedItems["timespan"])
        XCTAssertEqual(boundedItems["maxrecords"], "250")

        let empty = GDELTClient(transport: transport)
        do {
            _ = try await empty.articles(matching: GDELTQuery(text: "  "))
            XCTFail("Expected an empty query to be rejected")
        } catch let error as IntelError {
            guard case .validation = error else {
                XCTFail("Expected validation, got \(error)")
                return
            }
        }
    }

    func testClientSurfacesANonJSONBody() async throws {
        let client = GDELTClient(transport: StaticTransport(data: Data("Please limit requests".utf8)))
        do {
            _ = try await client.articles(matching: GDELTQuery(text: "Red Sea"))
            XCTFail("Expected the text body to fail")
        } catch let error as IntelError {
            guard case .gdelt = error else {
                XCTFail("Expected gdelt, got \(error)")
                return
            }
        }
    }

    private func mode(of url: URL) -> String? {
        queryItems(url)["mode"]
    }

    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

private actor FixtureTransport: GDELTTransport {
    let payloads: [String: Data]
    private var recorded: [URL] = []

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    func urls() -> [URL] {
        recorded
    }

    func data(for url: URL) async throws -> Data {
        recorded.append(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mode = items.first { $0.name == "mode" }?.value ?? ""
        guard let data = payloads[mode] else {
            throw IntelError.gdelt("no fixture for mode \(mode)")
        }
        return data
    }
}

private struct StaticTransport: GDELTTransport {
    var data: Data
    func data(for url: URL) async throws -> Data {
        data
    }
}
