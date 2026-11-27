import IntelKit
import SwiftUI
import UniformTypeIdentifiers

struct IntelSheetToken: Identifiable, Equatable {
    let id: String
}

@MainActor
final class IntelDirectory: ObservableObject {
    static let shared = IntelDirectory()

    private let store: IntelStore?
    @Published private(set) var entities: [Entity] = []
    @Published private(set) var graph = Subgraph(entities: [], links: [])
    @Published var status = ""
    @Published var busy = false

    private init() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = try IntelStore.onDisk(at: support.appendingPathComponent("intel.sqlite"))
        } catch {
            store = nil
            status = error.localizedDescription
        }
    }

    func reload() {
        guard let store else { return }
        do {
            entities = try store.entities(matching: EntityFilter(limit: 300))
            graph = try store.subgraph(matching: EntityFilter(limit: 60))
            let pins = try store.globePins()
            status = ""
            Task { await push(pins) }
        } catch {
            status = error.localizedDescription
        }
    }

    func entity(id: String) -> Entity? {
        try? store?.entity(id: id)
    }

    func neighbors(of id: String) -> [Neighbor] {
        (try? store?.neighbors(of: id)) ?? []
    }

    func importFile(_ url: URL) {
        guard let store else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        busy = true
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            let provenance = Provenance(source: "Files", retrievedAt: Date())
            if url.pathExtension.lowercased() == "json" {
                _ = try JSONImporter.importJSON(data, into: store, provenance: provenance)
            } else {
                let text = String(decoding: data, as: UTF8.self)
                _ = try CSVImporter.importCSV(text, into: store, provenance: provenance)
            }
            reload()
        } catch {
            status = error.localizedDescription
        }
    }

    func importGDELT(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, query.count >= 2 else { return }
        busy = true
        defer { busy = false }
        do {
            let client = GDELTClient()
            _ = try await client.importCoverage(
                GDELTQuery(text: query, timespan: .days(1), maxRecords: 25),
                into: store
            )
            reload()
        } catch {
            status = error.localizedDescription
        }
    }

    private func push(_ pins: [GlobePin]) async {
        let payload: [[String: Any]] = pins.prefix(200).map { pin in
            [
                "id": pin.id,
                "name": pin.name,
                "kind": pin.kind.rawValue,
                "lat": pin.latitude,
                "lon": pin.longitude,
            ]
        }
        do {
            _ = try await GlobeStore.shared.call(["op": "pins", "pins": payload])
        } catch {
            // The globe may still be starting. The next reload sends the pins again.
        }
    }
}

enum IntelPane: String, CaseIterable, Identifiable {
    case entities = "Entities"
    case graph = "Graph"
    case news = "News"
    var id: String { rawValue }
}

enum IntelKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case person = "People"
    case place = "Places"
    case event = "Events"
    case organization = "Orgs"
    var id: String { rawValue }
    var kinds: Set<EntityKind> {
        switch self {
        case .all: return []
        case .person: return [.person]
        case .place: return [.place]
        case .event: return [.event]
        case .organization: return [.organization]
        }
    }
}

struct IntelScreen: View {
    @ObservedObject private var directory = IntelDirectory.shared
    @Binding var tab: Int
    @State private var pane: IntelPane = .entities
    @State private var filter: IntelKindFilter = .all
    @State private var gdelt = ""
    @State private var importing = false
    @State private var detail: Entity?

    private var rows: [Entity] {
        directory.entities.filter { entity in
            filter.kinds.isEmpty || filter.kinds.contains(entity.kind)
        }
    }

    private var news: [Entity] {
        directory.entities.filter { entity in
            entity.kind == .event && entity.provenance.source.localizedCaseInsensitiveContains("GDELT")
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Intel", selection: $pane) {
                    ForEach(IntelPane.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                if !directory.status.isEmpty {
                    Text(directory.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                switch pane {
                case .entities:
                    entityList
                case .graph:
                    IntelGraphView(graph: directory.graph) { entity in
                        detail = entity
                    }
                case .news:
                    newsList
                }
            }
            .navigationTitle("Intel")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import")
                }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json, .commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result {
                directory.importFile(url)
            }
        }
        .sheet(item: $detail) { entity in
            IntelDetailSheet(entityID: entity.id, tab: $tab)
        }
        .task { directory.reload() }
    }

    private var entityList: some View {
        List {
            Picker("Kind", selection: $filter) {
                ForEach(IntelKindFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            if rows.isEmpty {
                Text("Import a CSV or JSON file, or pull a GDELT search from News.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { entity in
                Button {
                    detail = entity
                } label: {
                    IntelRow(entity: entity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var newsList: some View {
        List {
            Section {
                TextField("GDELT search", text: $gdelt)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { Task { await directory.importGDELT(gdelt) } }
                Button(directory.busy ? "Fetching…" : "Fetch GDELT") {
                    Task { await directory.importGDELT(gdelt) }
                }
                .disabled(directory.busy || gdelt.trimmingCharacters(in: .whitespaces).count < 2)
            } footer: {
                Text("Keyless GDELT DOC and GEO. Events, outlets, and places land in the graph.")
            }
            ForEach(news) { entity in
                Button {
                    detail = entity
                } label: {
                    IntelRow(entity: entity)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct IntelRow: View {
    let entity: Entity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entity.name).foregroundStyle(.primary).lineLimit(2)
            Text(entity.kind.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct IntelDetailSheet: View {
    let entityID: String
    @Binding var tab: Int
    @ObservedObject private var directory = IntelDirectory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var focus: String

    init(entityID: String, tab: Binding<Int>) {
        self.entityID = entityID
        _tab = tab
        _focus = State(initialValue: entityID)
    }

    var body: some View {
        NavigationView {
            Group {
                if let entity = directory.entity(id: focus) {
                    List {
                        Section {
                            LabeledContent("Kind", value: entity.kind.rawValue.capitalized)
                            LabeledContent("Source", value: entity.provenance.source)
                            if let when = entity.occurredAt {
                                LabeledContent("When", value: when.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let lat = entity.latitude, let lon = entity.longitude {
                                LabeledContent("Coordinates", value: String(format: "%.3f, %.3f", lat, lon))
                            }
                        }
                        if entity.hasCoordinates {
                            Section {
                                Button {
                                    Task {
                                        await GlobeStore.shared.fly(
                                            lat: entity.latitude ?? 0,
                                            lon: entity.longitude ?? 0,
                                            range: 40000
                                        )
                                        tab = 0
                                        dismiss()
                                    }
                                } label: {
                                    Label("Show on globe", systemImage: "location")
                                }
                            }
                        }
                        let linked = directory.neighbors(of: focus)
                        if !linked.isEmpty {
                            Section("Linked") {
                                ForEach(linked, id: \.entity.id) { neighbor in
                                    Button {
                                        focus = neighbor.entity.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(neighbor.entity.name).foregroundStyle(.primary)
                                            Text(neighbor.link.type.replacingOccurrences(of: "_", with: " "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .navigationTitle(entity.name)
                } else {
                    Text("That record is not in the graph.")
                        .foregroundStyle(.secondary)
                        .navigationTitle("Intel")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .modifier(MediumDetent())
    }
}

struct IntelGraphView: View {
    let graph: Subgraph
    var onSelect: (Entity) -> Void
    @State private var nodes: [GraphNode] = []
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                context.translateBy(x: offset.width + size.width / 2, y: offset.height + size.height / 2)
                context.scaleBy(x: scale, y: scale)
                var byID: [String: GraphNode] = [:]
                for node in nodes { byID[node.id] = node }
                for link in graph.links {
                    guard let from = byID[link.fromID], let to = byID[link.toID] else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: from.x, y: from.y))
                    path.addLine(to: CGPoint(x: to.x, y: to.y))
                    context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
                }
                for node in nodes {
                    let rect = CGRect(x: node.x - 16, y: node.y - 16, width: 32, height: 32)
                    context.fill(Path(ellipseIn: rect), with: .color(color(node.kind)))
                    context.draw(
                        Text(node.name).font(.caption2).foregroundColor(.white),
                        at: CGPoint(x: node.x, y: node.y + 24),
                        anchor: .top
                    )
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: dragOrigin.width + value.translation.width,
                            height: dragOrigin.height + value.translation.height
                        )
                    }
                    .onEnded { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        offset = CGSize(
                            width: dragOrigin.width + value.translation.width,
                            height: dragOrigin.height + value.translation.height
                        )
                        dragOrigin = offset
                        if moved < 10, let id = hit(value.location, in: proxy.size) {
                            if let entity = graph.entities.first(where: { $0.id == id }) {
                                onSelect(entity)
                            }
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(3, max(0.4, baseScale * value))
                    }
                    .onEnded { value in
                        baseScale = min(3, max(0.4, baseScale * value))
                        scale = baseScale
                    }
            )
            .task(id: graph.entities.map(\.id).joined(separator: "|")) {
                nodes = layout()
                for _ in 0..<70 {
                    step()
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
        }
    }

    private func layout() -> [GraphNode] {
        graph.entities.enumerated().map { index, entity in
            let angle = CGFloat(index) / CGFloat(max(graph.entities.count, 1)) * .pi * 2
            let radius: CGFloat = 80
            return GraphNode(
                id: entity.id,
                name: entity.name,
                kind: entity.kind,
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }
    }

    private func step() {
        guard nodes.count > 1 else { return }
        var next = nodes
        let ideal: CGFloat = 110
        for i in next.indices {
            for j in next.indices where j > i {
                let dx = next[j].x - next[i].x
                let dy = next[j].y - next[i].y
                let dist = max(20, hypot(dx, dy))
                let push = (ideal * ideal) / dist
                let ux = dx / dist
                let uy = dy / dist
                next[i].vx -= ux * push * 0.02
                next[i].vy -= uy * push * 0.02
                next[j].vx += ux * push * 0.02
                next[j].vy += uy * push * 0.02
            }
        }
        var byID: [String: Int] = [:]
        for (index, node) in next.enumerated() { byID[node.id] = index }
        for link in graph.links {
            guard let i = byID[link.fromID], let j = byID[link.toID] else { continue }
            let dx = next[j].x - next[i].x
            let dy = next[j].y - next[i].y
            let dist = max(1, hypot(dx, dy))
            let pull = (dist - ideal) * 0.02
            next[i].vx += dx / dist * pull
            next[i].vy += dy / dist * pull
            next[j].vx -= dx / dist * pull
            next[j].vy -= dy / dist * pull
        }
        for i in next.indices {
            next[i].vx += -next[i].x * 0.01
            next[i].vy += -next[i].y * 0.01
            next[i].vx *= 0.8
            next[i].vy *= 0.8
            next[i].x += next[i].vx
            next[i].y += next[i].vy
        }
        nodes = next
    }

    private func hit(_ location: CGPoint, in size: CGSize) -> String? {
        let x = (location.x - size.width / 2 - offset.width) / scale
        let y = (location.y - size.height / 2 - offset.height) / scale
        return nodes.first { node in
            hypot(node.x - x, node.y - y) < 22
        }?.id
    }

    private func color(_ kind: EntityKind) -> Color {
        switch kind {
        case .person: return .blue
        case .organization: return .purple
        case .place: return .green
        case .event: return .orange
        case .vessel: return .cyan
        case .aircraft: return .yellow
        }
    }
}

struct GraphNode: Identifiable {
    let id: String
    let name: String
    let kind: EntityKind
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat = 0
    var vy: CGFloat = 0
}
