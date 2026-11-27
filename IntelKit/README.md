# IntelKit

On-device link analysis for the God's Eye View iOS app. IntelKit stores people, organizations, places, events, vessels, and aircraft, the typed links between them, and where each record came from. A later Intel tab can draw the graph. The Cesium globe can pin any entity that has coordinates.

The package does not ship a UI, an API key, or a backend. GDELT is read from its public keyless endpoints when the app asks for it. Everything else stays in a local SQLite file.

## Requirements

- Swift 6.1 or newer (Xcode 16.3 or newer)
- iOS 16 or newer. macOS 13 or newer is declared so the same package tests can run on a Mac.
- [GRDB](https://github.com/groue/GRDB.swift) 7.12.0, which uses the system SQLite

## Adding it to the app

IntelKit is a local Swift package. In the native app target:

1. File → Add Package Dependencies → Add Local…
2. Choose this `IntelKit` directory.
3. Link the `IntelKit` library to the app target.

Do not import it from the Capacitor shell unless that target is ready to take a second local package. The package has no UIKit or SwiftUI dependency, so either app can call it.

Open the database under Application Support and keep the `IntelStore` for the lifetime of the process. One store per file.

```swift
import IntelKit

let support = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let store = try IntelStore.onDisk(at: support.appendingPathComponent("intel.sqlite"))
```

`IntelStore` is safe to call from any thread. Each call is its own transaction. Opening a second store on the same file is not supported.

Migrations run on open:

| Identifier | What it creates |
| --- | --- |
| `v1-entity-and-link` | `entity` and `link` tables, plus kind, time, and coordinate indexes |
| `v2-external-id-index` | indexes on `externalID` |

`appliedMigrations()` returns the identifiers that have run. Add a new `registerMigration` in `IntelMigrations` for later schema changes; do not edit a migration that has already shipped.

## Ontology

An `Entity` has an id, a `EntityKind`, a name, a property bag (`[String: JSONValue]`), optional `latitude` and `longitude` (both or neither), an optional time interval (`occurredAt`, `endedAt`), and a `Provenance`.

`Provenance` is the source name, the time this device stored the row (`retrievedAt`), an optional source URL, and an optional external id. It is not the time the real-world event happened. That time is `occurredAt`.

A `Link` is directed: `fromID`, `toID`, and a `type` string. These constants are the ones GDELT import uses; any other non-empty type is stored as-is.

| Constant | Meaning |
| --- | --- |
| `reported_by` | Event to the outlet that published it |
| `occurred_in` | Event to the place it was tied to |
| `based_in` | Outlet to the country GDELT named as its source country |
| `mentions` | Query hub to an event or place from that search |
| `affiliated_with` | Person or org to an organization |
| `participated_in` | Actor to an event |
| `located_at` | Something at a place |
| `operates` | Organization to a vessel or aircraft |

Upsert replaces the whole row for an id. Delete an entity and every link that touches it goes with it. A link whose endpoint is missing is rejected, and the transaction rolls back.

## Queries the graph and the globe can share

```swift
let hits = try store.search(name: "Aden", kinds: [.place], limit: 20)

let window = TimeWindow(start: scrubStart, end: scrubEnd)
let events = try store.entities(matching: EntityFilter(kinds: [.event], time: window))

let slice = try store.subgraph(matching: EntityFilter(time: window))
// slice.entities and slice.links are the graph at this scrubber position.

let around = try store.expand(from: selectedID, hops: 2, time: window)
let routes = try store.paths(from: selectedID, to: otherID, maxHops: 4)
let pins = try store.globePins(in: window)
```

`search` folds case and diacritics. Exact names rank above prefix matches, which rank above other substrings. `%` and `_` in the query are matched literally.

`entities(matching:)` is strict about time: a row matches when `[occurredAt, endedAt]` (or the single instant, when there is no end) overlaps the window. A row with no `occurredAt` is timeless and is left out of that list.

`subgraph(matching:)`, `globePins(in:)`, `neighbors`, `expand`, and `paths` keep a timeless row when the time window is set and the row is linked to something inside the window. A scrubber can hide events outside the range without dropping the outlets and places those events are attached to. `globePins` still requires coordinates. `GlobePin.id` is the entity id.

`expand` is breadth-first. The origin is always included. `hops` is the number of links to follow. `paths` returns simple paths, shortest first, and does not repeat an entity, so a node is not a path to itself. Both stop at a limit (`expand` defaults to 500 entities, `paths` to 20 paths).

## CSV and JSON import

Pass a fallback `Provenance`. A column or field on the row overrides it. Importing the same id again replaces the row.

```swift
let provenance = Provenance(source: "analyst", retrievedAt: Date())
_ = try CSVImporter.importCSV(csvText, into: store, provenance: provenance)
_ = try JSONImporter.importJSON(jsonData, into: store, provenance: provenance)
```

CSV headers ignore case, spaces, and underscores (`source_url` and `sourceURL` match). A file with a `record_type` column (`entity` or `link`) can carry both; entities are written first. Without that column, a file that has `from` / `to` is links, and anything else is entities.

Entity columns: `id`, `kind`, `name`, `latitude` (`lat`), `longitude` (`lon`, `lng`), `occurred_at`, `ended_at`, `source`, `source_url`, `external_id`, `retrieved_at`, `properties_json`. Other columns become string properties, keeping the header text. Kind aliases include `org`, `ship`, `plane`, and `location`. `from` / `to` on a link match an id, then a unique name.

JSON accepts `{ "entities": [], "links": [] }`, one entity object, or an array of entities. Keys may be camelCase or snake_case. Dates are ISO-8601, GDELT's `YYYYMMDDThhmmssZ`, or Unix seconds. Omit `id` and the importer builds a stable one from the kind, name, and external id.

## GDELT

`GDELTClient` talks to two keyless APIs:

- DOC 2.0, `https://api.gdeltproject.org/api/v2/doc/doc`, modes `artlist` and `timelinevolraw`
- GEO 2.0, `https://api.gdeltproject.org/api/v2/geo/geo`, mode `PointData` (GeoJSON)

No key is sent. The URL session transport sets a user agent, because GDELT rejects empty ones. Give the client a `GDELTTransport` in tests so they can parse fixtures instead of calling the network.

```swift
let client = GDELTClient()
let query = GDELTQuery(text: "Red Sea shipping", timespan: .days(1), maxRecords: 25)
let series = try await client.timeline(matching: query)   // volume buckets for a chart
let imported = try await client.importCoverage(query, into: store)
```

`importCoverage` fetches the article list and the geo points together and upserts one graph:

- Each article becomes an event. `occurredAt` is GDELT's `seendate`. The URL is the external id, so the same story from DOC and GEO is one event.
- The article's domain becomes an organization with `actor = true` and `role = publisher`, linked `reported_by`.
- The outlet's source country becomes a place with no coordinates, linked `based_in` from the outlet. That country is where the outlet is, not where the story happened.
- Each GEO point becomes a place with coordinates and a `mentionCount`. Articles parsed from that point's popup are events linked `occurred_in`.
- Unless `GDELTImportOptions(createQueryHub: false)` is passed, a timeless event named with the query is linked `mentions` to those events and places. Expand from that hub to reach the outlets on the next hop.

DOC artlist does not name the people in a story, so IntelKit does not invent person entities from headlines. Timeline buckets are returned to the caller and are not written as entities; scrub the stored events by `occurredAt` instead.

GDELT asks for about one request every few seconds. A burst often comes back as plain text. The decoder throws `IntelError.gdelt` with that text. When both `start` and `end` are set they are sent as `startdatetime` / `enddatetime` (`YYYYMMDDHHMMSS` UTC) and `timespan` is omitted. `maxRecords` is clamped to 1...250.

GDELT's content is theirs. The app should attribute places and events that came from this client to the GDELT Project. Provenance source is `GDELT DOC`, `GDELT GEO`, or `GDELT`.

## Errors

`IntelError` is `validation`, `notFound`, `malformedImport`, `gdelt`, or `database`. `notFound` means the id was wrong. An entity with no links returns an empty neighbor list rather than `notFound`.

## Tests

From this directory:

```sh
swift test
```

Tests cover migrations, upsert and rollback, search, time overlap, neighbors, expansion, paths, globe pins, CSV, JSON, and GDELT JSON parsing. GDELT tests use the files in `Tests/IntelKitTests/Fixtures` and a stand-in transport. They do not open a network connection.
