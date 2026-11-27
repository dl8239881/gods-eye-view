import Foundation
import XCTest
@testable import IntelKit

enum Fixture {
    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, file: StaticString = #filePath) throws -> String {
        String(decoding: try data(name, file: file), as: UTF8.self)
    }
}

func sampleProvenance(_ source: String = "manual", at seconds: TimeInterval = 1_700_000_000) -> Provenance {
    Provenance(source: source, retrievedAt: Date(timeIntervalSince1970: seconds))
}

func makeEntity(
    id: String,
    kind: EntityKind,
    name: String,
    latitude: Double? = nil,
    longitude: Double? = nil,
    occurredAt: Date? = nil,
    endedAt: Date? = nil,
    properties: [String: JSONValue] = [:]
) -> Entity {
    Entity(
        id: id,
        kind: kind,
        name: name,
        properties: properties,
        latitude: latitude,
        longitude: longitude,
        occurredAt: occurredAt,
        endedAt: endedAt,
        provenance: sampleProvenance()
    )
}

func makeLink(id: String = UUID().uuidString, type: String, from: String, to: String) -> Link {
    Link(id: id, type: type, fromID: from, toID: to, provenance: sampleProvenance())
}

func utcDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    _ second: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    )!
}

func XCTAssertUTC(
    _ date: Date?,
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    _ second: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let date else {
        XCTFail("Expected a date", file: file, line: line)
        return
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    XCTAssertEqual(parts.year, year, file: file, line: line)
    XCTAssertEqual(parts.month, month, file: file, line: line)
    XCTAssertEqual(parts.day, day, file: file, line: line)
    XCTAssertEqual(parts.hour, hour, file: file, line: line)
    XCTAssertEqual(parts.minute, minute, file: file, line: line)
    XCTAssertEqual(parts.second, second, file: file, line: line)
}
