import XCTest
@testable import IntelKit

final class ImporterTests: XCTestCase {
    func testCSVEntitiesQuotesPropertiesAndKindAliases() throws {
        let store = try IntelStore.inMemory()
        let csv = try Fixture.text("entities.csv")
        let result = try CSVImporter.importEntities(csv, into: store, provenance: sampleProvenance("sheet"))
        XCTAssertEqual(result.entitiesUpserted, 3)

        let ada = try XCTUnwrap(try store.entity(id: "p-ada"))
        XCTAssertEqual(ada.name, "Lovelace, Ada")
        XCTAssertEqual(ada.kind, .person)
        XCTAssertEqual(ada.properties["born"]?.number, 1815)
        XCTAssertEqual(ada.provenance.source, "sheet")

        let ship = try XCTUnwrap(try store.entity(id: "v-1"))
        XCTAssertEqual(ship.kind, .vessel)
        XCTAssertEqual(ship.latitude, 12.8)
        XCTAssertEqual(ship.longitude, 45.03)
        XCTAssertEqual(ship.properties["Call Sign"]?.string, "H3RC")

        let canal = try XCTUnwrap(try store.entity(id: "place-suez"))
        XCTAssertEqual(canal.kind, .place)
        XCTAssertEqual(try store.globePins().map(\.id).sorted(), ["place-suez", "v-1"])
    }

    func testCSVLinksResolveNamesAndMixedFileImportsBoth() throws {
        let store = try IntelStore.inMemory()
        let mixed = """
        record_type,id,kind,name,type,from_id,to_id,latitude,longitude
        entity,ship-1,ship,Ever Given,,,,,
        entity,place-1,place,Suez Canal,,,,30.5,32.3
        link,,,,located_at,Ever Given,Suez Canal,,
        """
        let result = try CSVImporter.importCSV(mixed, into: store, provenance: sampleProvenance())
        XCTAssertEqual(result.entitiesUpserted, 2)
        XCTAssertEqual(result.linksUpserted, 1)
        let link = try XCTUnwrap(try store.neighbors(of: "ship-1").first)
        XCTAssertEqual(link.entity.id, "place-1")
        XCTAssertEqual(link.link.type, LinkType.locatedAt)
        XCTAssertEqual(link.direction, .outgoing)

        let again = try CSVImporter.importCSV(mixed, into: store, provenance: sampleProvenance())
        XCTAssertEqual(again.entitiesUpserted, 2)
        XCTAssertEqual(try store.entityCount(), 2)
        XCTAssertEqual(try store.linkCount(), 1)
    }

    func testCSVQuotedNewlineAndAmbiguousName() throws {
        let store = try IntelStore.inMemory()
        let csv = "id,kind,name\np1,person,\"Ada\nLovelace\"\n"
        _ = try CSVImporter.importEntities(csv, into: store, provenance: sampleProvenance())
        XCTAssertEqual(try store.entity(id: "p1")?.name, "Ada\nLovelace")

        try store.upsert(entities: [
            makeEntity(id: "s1", kind: .person, name: "Sam"),
            makeEntity(id: "s2", kind: .person, name: "Sam"),
            makeEntity(id: "org", kind: .organization, name: "Lab"),
        ], links: [])
        let links = "type,from,to\naffiliated_with,Sam,Lab\n"
        XCTAssertThrowsError(try CSVImporter.importLinks(links, into: store, provenance: sampleProvenance())) { error in
            guard case IntelError.malformedImport(let message) = error else {
                return XCTFail("Expected malformedImport, got \(error)")
            }
            XCTAssertTrue(message.contains("matches"))
        }
    }

    func testCSVRejectsUnknownKindAndAShortRow() throws {
        let store = try IntelStore.inMemory()
        XCTAssertThrowsError(
            try CSVImporter.importEntities(
                "kind,name\nwidget,Thing\n",
                into: store,
                provenance: sampleProvenance()
            )
        )
        XCTAssertThrowsError(
            try CSVImporter.importEntities(
                "kind,name\nperson\n",
                into: store,
                provenance: sampleProvenance()
            )
        )
        XCTAssertEqual(try store.entityCount(), 0)
    }

    func testJSONSnakeCaseAndGeneratedIDs() throws {
        let store = try IntelStore.inMemory()
        let result = try JSONImporter.importJSON(
            try Fixture.data("graph.json"),
            into: store,
            provenance: sampleProvenance("fallback")
        )
        XCTAssertEqual(result.entitiesUpserted, 2)
        XCTAssertEqual(result.linksUpserted, 1)
        let jose = try XCTUnwrap(try store.entity(id: "person-jose"))
        XCTAssertEqual(jose.properties["role"]?.string, "writer")
        XCTAssertEqual(jose.provenance.externalID, "jose")
        XCTAssertUTC(jose.occurredAt, 1853, 1, 28, 0, 0, 0)
        let link = try XCTUnwrap(try store.neighbors(of: "person-jose").first)
        XCTAssertEqual(link.entity.id, "org-havana")
        XCTAssertEqual(link.link.type, LinkType.affiliatedWith)

        let single = """
        {"kind":"aircraft","name":"N12345","latitude":40.6,"longitude":-73.7}
        """
        _ = try JSONImporter.importJSON(single, into: store, provenance: sampleProvenance("sheet"))
        let aircraft = try store.entities(exactlyNamed: "N12345")
        XCTAssertEqual(aircraft.count, 1)
        XCTAssertEqual(aircraft.first?.kind, .aircraft)
        XCTAssertEqual(aircraft.first?.provenance.source, "sheet")
        _ = try JSONImporter.importJSON(single, into: store, provenance: sampleProvenance("sheet"))
        XCTAssertEqual(try store.entities(exactlyNamed: "N12345").count, 1)
    }

    func testJSONArrayOfEntities() throws {
        let store = try IntelStore.inMemory()
        let json = """
        [
          {"id":"a","kind":"person","name":"Ada"},
          {"id":"b","kind":"person","name":"Grace","lat":"42.3","lon":"-71.1"}
        ]
        """
        _ = try JSONImporter.importJSON(json, into: store, provenance: sampleProvenance())
        XCTAssertEqual(try store.entityCount(), 2)
        XCTAssertEqual(try store.entity(id: "b")?.latitude, 42.3)
        XCTAssertEqual(try store.entity(id: "b")?.longitude, -71.1)
    }
}
