import XCTest
@testable import IntelKit

final class QueryTests: XCTestCase {
    private func populated() throws -> IntelStore {
        let store = try IntelStore.inMemory()
        let conferenceStart = utcDate(2024, 6, 1, 10)
        let conferenceEnd = utcDate(2024, 6, 1, 12)
        try store.upsert(entities: [
            makeEntity(id: "ada", kind: .person, name: "Ada Lovelace"),
            makeEntity(id: "madame", kind: .person, name: "Madame Ada"),
            makeEntity(id: "adana", kind: .place, name: "Adana", latitude: 37.0, longitude: 35.3),
            makeEntity(id: "jose", kind: .person, name: "José Martí"),
            makeEntity(id: "pct", kind: .organization, name: "100%_ready"),
            makeEntity(id: "plain", kind: .organization, name: "100Xready"),
            makeEntity(id: "org", kind: .organization, name: "Analytical Engines"),
            makeEntity(id: "london", kind: .place, name: "London", latitude: 51.5, longitude: -0.12),
            makeEntity(
                id: "conference",
                kind: .event,
                name: "Conference",
                occurredAt: conferenceStart,
                endedAt: conferenceEnd
            ),
            makeEntity(id: "babbage", kind: .person, name: "Charles Babbage"),
            makeEntity(id: "old", kind: .event, name: "Old Meeting", occurredAt: utcDate(2020, 1, 1)),
            makeEntity(id: "paris", kind: .place, name: "Paris", latitude: 48.8, longitude: 2.3),
            makeEntity(id: "nowhere", kind: .place, name: "Nowhere", latitude: 0, longitude: 0),
            makeEntity(
                id: "edge",
                kind: .event,
                name: "Edge",
                occurredAt: utcDate(2024, 6, 1, 8),
                endedAt: utcDate(2024, 6, 1, 11)
            ),
        ], links: [
            makeLink(id: "l-aff", type: LinkType.affiliatedWith, from: "ada", to: "org"),
            makeLink(id: "l-back", type: LinkType.mentions, from: "org", to: "ada"),
            makeLink(id: "l-org-city", type: LinkType.locatedAt, from: "org", to: "london"),
            makeLink(id: "l-ada-event", type: LinkType.participatedIn, from: "ada", to: "conference"),
            makeLink(id: "l-bab-event", type: LinkType.participatedIn, from: "babbage", to: "conference"),
            makeLink(id: "l-event-city", type: LinkType.locatedAt, from: "conference", to: "london"),
            makeLink(id: "l-old", type: LinkType.locatedAt, from: "old", to: "paris"),
        ])
        return store
    }

    func testSearchRanksExactThenPrefixAndFoldsDiacritics() throws {
        let store = try populated()
        let ada = try store.search(name: "ada").map(\.id)
        XCTAssertEqual(ada, ["ada", "adana", "madame"])
        XCTAssertEqual(try store.search(name: "ada lovelace").map(\.id), ["ada"])
        XCTAssertEqual(try store.search(name: "jose").map(\.name), ["José Martí"])
        XCTAssertEqual(try store.search(name: "  ").map(\.id), [])
        XCTAssertEqual(try store.search(name: "ada", kinds: [.place]).map(\.id), ["adana"])
    }

    func testSearchEscapesLikeWildcards() throws {
        let store = try populated()
        XCTAssertEqual(try store.search(name: "100%").map(\.id), ["pct"])
        XCTAssertEqual(try store.search(name: "100%_").map(\.id), ["pct"])
        XCTAssertTrue(try store.search(name: "100X").map(\.id).contains("plain"))
    }

    func testTimeFilterIsStrictAndSubgraphKeepsTimelessContext() throws {
        let store = try populated()
        // Conference runs 10:00–12:00. Edge runs 08:00–11:00. A window that
        // opens at 11:01 includes only the conference; a window that opens
        // at 11:00 still touches the edge because the bounds are inclusive.
        let window = TimeWindow(start: utcDate(2024, 6, 1, 11, 1), end: utcDate(2024, 6, 1, 11, 30))
        let timed = try store.entities(matching: EntityFilter(time: window)).map(\.id)
        XCTAssertEqual(Set(timed), ["conference"])

        let touching = TimeWindow(start: utcDate(2024, 6, 1, 11), end: utcDate(2024, 6, 1, 11))
        let edge = try store.entities(matching: EntityFilter(time: touching)).map(\.id)
        XCTAssertTrue(Set(edge).isSuperset(of: ["edge", "conference"]))

        let graph = try store.subgraph(matching: EntityFilter(time: window))
        XCTAssertEqual(Set(graph.entities.map(\.id)), ["conference", "ada", "babbage", "london"])
        XCTAssertEqual(Set(graph.links.map(\.id)), ["l-ada-event", "l-bab-event", "l-event-city"])
    }

    func testNeighborsDirectionsAndMissingOrigin() throws {
        let store = try populated()
        let outgoing = try store.neighbors(of: "ada", direction: .outgoing).map(\.entity.id)
        XCTAssertEqual(outgoing, ["org", "conference"])
        let incoming = try store.neighbors(of: "ada", direction: .incoming).map(\.entity.id)
        XCTAssertEqual(incoming, ["org"])
        let typed = try store.neighbors(of: "ada", linkTypes: [LinkType.affiliatedWith]).map(\.link.id)
        XCTAssertEqual(typed, ["l-aff"])
        XCTAssertThrowsError(try store.neighbors(of: "missing")) { error in
            guard case IntelError.notFound = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    func testExpandStopsOnCyclesAndHonorsHopLimit() throws {
        let store = try populated()
        let one = try store.expand(from: "ada", hops: 1)
        XCTAssertEqual(Set(one.entities.map(\.id)), ["ada", "org", "conference"])
        let wide = try store.expand(from: "ada", hops: 5)
        XCTAssertEqual(
            Set(wide.entities.map(\.id)),
            ["ada", "org", "conference", "london", "babbage"]
        )
        XCTAssertEqual(wide.entities.first?.id, "ada")
        let affiliated = try store.expand(from: "ada", hops: 2, linkTypes: [LinkType.affiliatedWith])
        XCTAssertEqual(Set(affiliated.entities.map(\.id)), ["ada", "org"])
    }

    func testExpandTimeKeepsUndatedNeighbors() throws {
        let store = try populated()
        let window = TimeWindow(start: utcDate(2024, 6, 1, 11, 1), end: utcDate(2024, 6, 1, 11, 30))
        let graph = try store.expand(from: "conference", hops: 1, time: window)
        XCTAssertEqual(Set(graph.entities.map(\.id)), ["conference", "ada", "babbage", "london"])
        XCTAssertFalse(graph.entities.map(\.id).contains("old"))
    }

    func testPathsAreSimpleAndShortestFirst() throws {
        let store = try populated()
        let paths = try store.paths(from: "ada", to: "london", maxHops: 2)
        XCTAssertEqual(paths.count, 3)
        XCTAssertTrue(paths.allSatisfy { $0.hopCount == 2 })
        let via = Set(paths.map { $0.entities.map(\.id) })
        XCTAssertEqual(
            via,
            Set([["ada", "org", "london"], ["ada", "conference", "london"]])
        )
        let firstHops = paths
            .filter { $0.entities.map(\.id) == ["ada", "org", "london"] }
            .map { $0.links[0].id }
        XCTAssertEqual(Set(firstHops), ["l-aff", "l-back"])
        XCTAssertTrue(try store.paths(from: "ada", to: "london", maxHops: 1).isEmpty)
        XCTAssertTrue(try store.paths(from: "ada", to: "ada", maxHops: 4).isEmpty)
        XCTAssertThrowsError(try store.paths(from: "ada", to: "missing"))
    }

    func testGlobePinsUseCoordinatesAndTheWindow() throws {
        let store = try populated()
        let all = try store.globePins()
        XCTAssertEqual(Set(all.map(\.id)), ["adana", "london", "paris", "nowhere"])
        XCTAssertEqual(all.first { $0.id == "london" }?.latitude, 51.5)

        let window = TimeWindow(start: utcDate(2024, 6, 1, 11, 1), end: utcDate(2024, 6, 1, 11, 30))
        let pins = try store.globePins(in: window)
        XCTAssertEqual(Set(pins.map(\.id)), ["london"])
        let places = try store.globePins(in: window, kinds: [.person])
        XCTAssertTrue(places.isEmpty)
    }

    func testExactNameMatch() throws {
        let store = try populated()
        XCTAssertEqual(try store.entities(exactlyNamed: "ada lovelace").map(\.id), ["ada"])
        XCTAssertTrue(try store.entities(exactlyNamed: "ada").isEmpty)
    }
}
