import XCTest
@testable import IntelKit

final class StoreTests: XCTestCase {
    func testMigrationsAreRecordedInOrder() throws {
        let store = try IntelStore.inMemory()
        XCTAssertEqual(
            try store.appliedMigrations(),
            ["v1-entity-and-link", "v2-external-id-index"]
        )
        XCTAssertEqual(try store.entityCount(), 0)
        XCTAssertEqual(try store.linkCount(), 0)
        XCTAssertNil(store.path)
    }

    func testDiskStoreSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intelkit-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("intel.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try IntelStore.onDisk(at: url)
        try store.upsert(makeEntity(id: "p1", kind: .person, name: "Ada Lovelace"))
        XCTAssertEqual(store.path, url.path)

        let reopened = try IntelStore(path: url.path)
        XCTAssertEqual(try reopened.appliedMigrations().count, 2)
        XCTAssertEqual(try reopened.entity(id: "p1")?.name, "Ada Lovelace")
    }

    func testInMemoryStoresAreIndependent() throws {
        let first = try IntelStore.inMemory()
        let second = try IntelStore.inMemory()
        try first.upsert(makeEntity(id: "p1", kind: .person, name: "Ada"))
        XCTAssertNil(try second.entity(id: "p1"))
    }

    func testUpsertReplacesAndDeleteCascadesLinks() throws {
        let store = try IntelStore.inMemory()
        try store.upsert(makeEntity(id: "a", kind: .person, name: "Ada", properties: ["title": "analyst"]))
        try store.upsert(makeEntity(id: "b", kind: .organization, name: "Analytical Engines"))
        try store.upsert(makeLink(id: "l1", type: LinkType.affiliatedWith, from: "a", to: "b"))
        try store.upsert(makeEntity(id: "a", kind: .person, name: "Ada Lovelace", properties: ["born": 1815]))

        let ada = try XCTUnwrap(try store.entity(id: "a"))
        XCTAssertEqual(ada.name, "Ada Lovelace")
        XCTAssertEqual(ada.properties["born"]?.number, 1815)
        XCTAssertNil(ada.properties["title"])
        XCTAssertEqual(try store.link(id: "l1")?.type, LinkType.affiliatedWith)

        XCTAssertTrue(try store.deleteEntity(id: "a"))
        XCTAssertFalse(try store.deleteEntity(id: "a"))
        XCTAssertNil(try store.entity(id: "a"))
        XCTAssertNil(try store.link(id: "l1"))
        XCTAssertNotNil(try store.entity(id: "b"))
        XCTAssertEqual(try store.linkCount(), 0)
    }

    func testMissingLinkEndpointRollsBackTheBatch() throws {
        let store = try IntelStore.inMemory()
        let entity = makeEntity(id: "a", kind: .person, name: "Ada")
        let link = makeLink(id: "l1", type: "knows", from: "a", to: "missing")
        XCTAssertThrowsError(try store.upsert(entities: [entity], links: [link])) { error in
            guard case IntelError.notFound = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
        XCTAssertEqual(try store.entityCount(), 0)
        XCTAssertEqual(try store.linkCount(), 0)
    }

    func testHalfACoordinateAndAnInvertedIntervalAreRejected() throws {
        let store = try IntelStore.inMemory()
        XCTAssertThrowsError(
            try store.upsert(makeEntity(id: "p", kind: .place, name: "Half", latitude: 10))
        ) { error in
            guard case IntelError.validation = error else {
                return XCTFail("Expected validation, got \(error)")
            }
        }
        let start = utcDate(2024, 6, 2)
        let end = utcDate(2024, 6, 1)
        XCTAssertThrowsError(
            try store.upsert(
                makeEntity(id: "e", kind: .event, name: "Backwards", occurredAt: start, endedAt: end)
            )
        )
        XCTAssertEqual(try store.entityCount(), 0)
    }

    func testDeleteLinkLeavesEntities() throws {
        let store = try IntelStore.inMemory()
        try store.upsert(entities: [
            makeEntity(id: "a", kind: .person, name: "Ada"),
            makeEntity(id: "b", kind: .person, name: "Charles"),
        ], links: [
            makeLink(id: "l1", type: "knows", from: "a", to: "b"),
        ])
        XCTAssertTrue(try store.deleteLink(id: "l1"))
        XCTAssertFalse(try store.deleteLink(id: "l1"))
        XCTAssertEqual(try store.entityCount(), 2)
        XCTAssertEqual(try store.linkCount(), 0)
    }
}
