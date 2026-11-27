import Capacitor
import SwiftUI
import UIKit
import WebKit

final class GevHandler: NSObject, WKScriptMessageHandler {
    var onPick: (([String: Any]) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "gev", let body = message.body as? [String: Any] else { return }
        guard (body["type"] as? String) == "pick" else { return }
        onPick?(body)
    }
}

/// Puts a web-view scroll offset back to zero without re-entering forever.
final class ScrollOffsetPin: NSObject {
    private var observation: NSKeyValueObservation?
    private var pinning = false

    func pin(_ scroll: UIScrollView) {
        if scroll.contentOffset != .zero {
            pinning = true
            scroll.setContentOffset(.zero, animated: false)
            pinning = false
        }
        guard observation == nil else { return }
        observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            guard let self, !self.pinning, scroll.contentOffset != .zero else { return }
            self.pinning = true
            scroll.setContentOffset(.zero, animated: false)
            self.pinning = false
        }
    }
}

enum GevCallError: LocalizedError {
    case notReady
    case badJSON

    var errorDescription: String? {
        switch self {
        case .notReady: return "The globe is still starting."
        case .badJSON: return "Could not read the globe."
        }
    }
}

struct EntityPick: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let lat: Double?
    let lon: Double?

    init(_ body: [String: Any]) {
        title = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Selection"
        detail = (body["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lat = jsonDouble(body["lat"])
        lon = jsonDouble(body["lon"])
    }
}

struct NativeChip: Identifiable {
    let id: String
    let label: String
    let active: Bool
    let params: [String: Any]
}

struct NativeLayer: Identifiable {
    let id: String
    let name: String
    var enabled: Bool
    let status: String
    let detail: String
    let subgroups: [NativeChip]
}

struct NativeGroup: Identifiable {
    var id: String { name }
    let name: String
    var layers: [NativeLayer]
}

struct TrafficCamera: Identifiable {
    let id: String
    let name: String
    let city: String
    let provider: String
    let lat: Double
    let lon: Double
    let image: String
}

struct PlaceHit: Identifiable {
    var id: String { "\(lat),\(lon),\(name)" }
    let name: String
    let lat: Double
    let lon: Double
}

@MainActor
final class GlobeStore: ObservableObject {
    static let shared = GlobeStore()

    private(set) lazy var bridge = CAPBridgeViewController()
    let handler = GevHandler()

    @Published var pick: EntityPick?
    @Published var intelSheet: IntelSheetToken?
    @Published var groups: [NativeGroup] = []
    @Published var cameras: [TrafficCamera] = []
    @Published var places: [PlaceHit] = []
    @Published var uplink = ""
    @Published var quality = "medium"
    @Published var status = "The globe is still starting."
    @Published var busy = false

    private var hookedView: WKWebView?
    private var maintaining = false

    var webView: WKWebView? { bridge.webView }

    func startMaintenance() {
        guard !maintaining else { return }
        maintaining = true
        handler.onPick = { [weak self] body in
            Task { @MainActor in
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let intel = (body["intelId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !intel.isEmpty {
                    self.intelSheet = IntelSheetToken(id: intel)
                    return
                }
                self.pick = EntityPick(body)
            }
        }
        tick()
    }

    private func tick() {
        maintain()
        let delay: TimeInterval = hookedView == nil ? 0.25 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.tick()
        }
    }

    private func maintain() {
        guard let webView else { return }
        if hookedView !== webView {
            webView.configuration.userContentController.add(handler, name: "gev")
            hookedView = webView
            webView.isOpaque = false
            webView.backgroundColor = UIColor(red: 10 / 255, green: 10 / 255, blue: 15 / 255, alpha: 1)
            webView.scrollView.backgroundColor = webView.backgroundColor
        }
        lock(webView)
    }

    private let offsetPin = ScrollOffsetPin()

    private func lock(_ webView: WKWebView) {
        let scroll = webView.scrollView
        scroll.isScrollEnabled = false
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.bouncesZoom = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        if scroll.zoomScale != 1 { scroll.zoomScale = 1 }
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = .zero
        scroll.scrollIndicatorInsets = .zero
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = false
        // Leaving the pan recognizer enabled, even with a high touch minimum,
        // lets it fail a one-finger drag and cancel the pointer Cesium is using.
        scroll.panGestureRecognizer.isEnabled = false
        scroll.pinchGestureRecognizer?.isEnabled = false
        for recognizer in scroll.gestureRecognizers ?? [] {
            if recognizer is UIPanGestureRecognizer || recognizer is UIPinchGestureRecognizer {
                recognizer.isEnabled = false
            }
            if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 {
                tap.isEnabled = false
            }
        }
        offsetPin.pin(scroll)
        webView.isMultipleTouchEnabled = true
    }

    func callWhenReady(_ command: [String: Any], tries: Int = 40) async throws -> Any? {
        var last: Error = GevCallError.notReady
        for attempt in 0..<tries {
            do {
                return try await call(command)
            } catch {
                last = error
                if attempt + 1 == tries || Task.isCancelled { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw last
    }

    func call(_ command: [String: Any]) async throws -> Any? {
        guard let webView else { throw GevCallError.notReady }
        let data = try JSONSerialization.data(withJSONObject: command)
        guard let json = String(data: data, encoding: .utf8) else { throw GevCallError.badJSON }
        let source = "return await globalThis.gevShell.apply(\(json));"
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func refreshLayers() async {
        busy = true
        defer { busy = false }
        do {
            let value = try await callWhenReady(["op": "layers"])
            groups = decodeGroups(value)
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    func setLayer(_ id: String, enabled: Bool) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            let value = try await call(["op": "setLayer", "id": id, "enabled": enabled])
            groups = decodeGroups(value)
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    func setParams(_ id: String, params: [String: Any]) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            let value = try await call(["op": "params", "id": id, "params": params])
            groups = decodeGroups(value)
        } catch {
            status = error.localizedDescription
        }
    }

    func loadCameras() async {
        busy = true
        defer { busy = false }
        do {
            let value = try await callWhenReady(["op": "cameras"])
            cameras = (value as? [Any] ?? []).compactMap(decodeCamera)
            status = cameras.isEmpty ? "No public cameras returned." : ""
        } catch {
            status = error.localizedDescription
        }
    }

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            places = []
            return
        }
        busy = true
        defer { busy = false }
        do {
            let value = try await callWhenReady(["op": "search", "q": q])
            places = (value as? [Any] ?? []).compactMap(decodePlace)
            status = places.isEmpty ? "No matches." : ""
        } catch {
            status = error.localizedDescription
        }
    }

    func fly(lat: Double, lon: Double, range: Double = 18000) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            _ = try await call([
                "op": "fly",
                "lat": lat,
                "lon": lon,
                "range": range,
            ])
        } catch {
            status = error.localizedDescription
        }
    }

    func wakeGlobe() async {
        webView?.setNeedsLayout()
        do {
            _ = try await call(["op": "wake"])
        } catch {
            status = ""
        }
    }

    func loadSettings() async {
        do {
            let value = try await callWhenReady(["op": "settings"])
            let body = value as? [String: Any] ?? [:]
            uplink = body["uplink"] as? String ?? ""
            quality = body["quality"] as? String ?? "medium"
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    func saveUplink(_ url: String) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            _ = try await call(["op": "uplink", "url": url])
        } catch {
            status = error.localizedDescription
        }
    }

    func saveQuality(_ level: String) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        quality = level
        do {
            _ = try await call(["op": "quality", "level": level])
        } catch {
            status = error.localizedDescription
        }
    }
}

private func decodeGroups(_ value: Any?) -> [NativeGroup] {
    let body = value as? [String: Any]
    let groups = body?["groups"] as? [Any] ?? []
    return groups.compactMap { item in
        guard let group = item as? [String: Any], let name = group["name"] as? String else { return nil }
        let layers = (group["layers"] as? [Any] ?? []).compactMap(decodeLayer)
        return NativeGroup(name: name, layers: layers)
    }
}

private func decodeLayer(_ value: Any) -> NativeLayer? {
    guard let layer = value as? [String: Any], let id = layer["id"] as? String else { return nil }
    let chips = (layer["subgroups"] as? [Any] ?? []).compactMap { item -> NativeChip? in
        guard let chip = item as? [String: Any], let chipId = chip["id"] as? String else { return nil }
        return NativeChip(
            id: chipId,
            label: chip["label"] as? String ?? chipId,
            active: jsonBool(chip["active"]),
            params: chip["params"] as? [String: Any] ?? [:]
        )
    }
    return NativeLayer(
        id: id,
        name: layer["name"] as? String ?? id,
        enabled: jsonBool(layer["enabled"]),
        status: layer["status"] as? String ?? "off",
        detail: layer["detail"] as? String ?? "",
        subgroups: chips
    )
}

private func decodeCamera(_ value: Any) -> TrafficCamera? {
    guard let camera = value as? [String: Any], let id = camera["id"] as? String else { return nil }
    return TrafficCamera(
        id: id,
        name: camera["name"] as? String ?? id,
        city: camera["city"] as? String ?? "",
        provider: camera["provider"] as? String ?? "",
        lat: jsonDouble(camera["lat"]) ?? .nan,
        lon: jsonDouble(camera["lon"]) ?? .nan,
        image: camera["image"] as? String ?? ""
    )
}

private func decodePlace(_ value: Any) -> PlaceHit? {
    guard let place = value as? [String: Any] else { return nil }
    let lat = jsonDouble(place["lat"])
    let lon = jsonDouble(place["lon"])
    guard let lat, let lon, lat.isFinite, lon.isFinite else { return nil }
    return PlaceHit(name: place["name"] as? String ?? "Place", lat: lat, lon: lon)
}

private func jsonBool(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return false
}

private func jsonDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    return nil
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct GlobeRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CAPBridgeViewController {
        GlobeStore.shared.bridge
    }

    func updateUIViewController(_ controller: CAPBridgeViewController, context: Context) {
        GlobeStore.shared.startMaintenance()
    }
}

struct GevRootView: View {
    @ObservedObject private var store = GlobeStore.shared
    @State private var tab = 0
    @State private var searchOpen = false

    var body: some View {
        // The web view stays in the window on every tab. Removing it with the
        // Globe page suspends WKWebView, and the next visit is a black frame
        // that ignores the next drag.
        ZStack {
            GlobeRepresentable()
                .ignoresSafeArea()
                .allowsHitTesting(tab == 0)
                .overlay(alignment: .topTrailing) {
                    if tab == 0 {
                        Button {
                            searchOpen = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.semibold))
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                        .accessibilityLabel("Search")
                    }
                }
            if tab != 0 {
                tabPage
                    .padding(.bottom, 49)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255)
                            .ignoresSafeArea()
                    )
            }
        }
        .overlay(alignment: .bottom) { tabBar }
        .preferredColorScheme(.dark)
        .sheet(item: $store.pick) { pick in
            EntitySheet(pick: pick, tab: $tab)
        }
        .sheet(isPresented: $searchOpen) {
            SearchScreen(tab: $tab)
        }
        .sheet(item: $store.intelSheet) { token in
            IntelDetailSheet(entityID: token.id, tab: $tab)
        }
        .onAppear {
            store.startMaintenance()
            IntelDirectory.shared.reload()
        }
        .onChange(of: tab, perform: { selected in
            if selected == 0 {
                Task { await store.wakeGlobe() }
            }
        })
    }

    @ViewBuilder
    private var tabPage: some View {
        switch tab {
        case 1: LayersScreen()
        case 2: CamerasScreen(tab: $tab)
        case 3: IntelScreen(tab: $tab)
        default: SettingsScreen()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(0, "Globe", "globe.americas")
            tabButton(1, "Layers", "square.3.layers.3d")
            tabButton(2, "Cameras", "video")
            tabButton(3, "Intel", "point.3.connected.trianglepath.dotted")
            tabButton(4, "Settings", "gearshape")
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.ultraThinMaterial)
    }

    private func tabButton(_ index: Int, _ title: String, _ symbol: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tab = index
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(tab == index ? Color.accentColor : Color.secondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct LayersScreen: View {
    @ObservedObject private var store = GlobeStore.shared

    var body: some View {
        NavigationView {
            List {
                if !store.status.isEmpty {
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.groups) { group in
                    Section(group.name) {
                        ForEach(group.layers) { layer in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: binding(for: layer)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(layer.name)
                                        if let caption = caption(layer) {
                                            Text(caption)
                                                .font(.caption)
                                                .foregroundStyle(captionColor(layer))
                                        }
                                    }
                                }
                                if layer.enabled && !layer.subgroups.isEmpty {
                                    ForEach(layer.subgroups) { chip in
                                        Button {
                                            Task { await store.setParams(layer.id, params: chip.params) }
                                        } label: {
                                            HStack {
                                                Text(chip.label).font(.subheadline)
                                                Spacer()
                                                if chip.active {
                                                    Image(systemName: "checkmark")
                                                        .font(.footnote.weight(.semibold))
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await store.refreshLayers() }
        }
        .navigationViewStyle(.stack)
        .task { await store.refreshLayers() }
    }

    private func binding(for layer: NativeLayer) -> Binding<Bool> {
        Binding(
            get: {
                store.groups
                    .flatMap(\.layers)
                    .first { $0.id == layer.id }?
                    .enabled ?? layer.enabled
            },
            set: { enabled in Task { await store.setLayer(layer.id, enabled: enabled) } }
        )
    }

    private func caption(_ layer: NativeLayer) -> String? {
        switch layer.status {
        case "ok": return "OK"
        case "unavailable": return layer.detail.isEmpty ? "Unavailable" : layer.detail
        case "needs-server": return "Needs server"
        case "loading": return "Loading"
        case "off": return layer.detail.isEmpty ? nil : layer.detail
        default: return nil
        }
    }

    private func captionColor(_ layer: NativeLayer) -> Color {
        switch layer.status {
        case "ok": return .green
        case "unavailable": return .orange
        case "needs-server": return .secondary
        default: return .secondary
        }
    }
}

struct CamerasScreen: View {
    @ObservedObject private var store = GlobeStore.shared
    @Binding var tab: Int
    @State private var camera: TrafficCamera?

    var body: some View {
        NavigationView {
            List(store.cameras) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera = item
                } label: {
                    HStack(spacing: 12) {
                        thumbnail(item.image)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).foregroundStyle(.primary).lineLimit(2)
                            Text([item.city, item.provider].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if store.busy && store.cameras.isEmpty { ProgressView() }
            }
            .navigationTitle("Cameras")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await store.loadCameras() }
        }
        .navigationViewStyle(.stack)
        .task { if store.cameras.isEmpty { await store.loadCameras() } }
        .sheet(item: $camera) { item in
            CameraSheet(camera: item, tab: $tab)
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: String) -> some View {
        if let image = URL(string: url), !url.isEmpty {
            AsyncImage(url: image) { phase in
                if let picture = phase.image {
                    picture.resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct CameraSheet: View {
    let camera: TrafficCamera
    @Binding var tab: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = URL(string: camera.image), !camera.image.isEmpty {
                    AsyncImage(url: image) { phase in
                        if let picture = phase.image {
                            picture.resizable().scaledToFit()
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(camera.name).font(.headline)
                Text([camera.city, camera.provider].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task {
                        await GlobeStore.shared.fly(lat: camera.lat, lon: camera.lon, range: 2500)
                        tab = 0
                        dismiss()
                    }
                } label: {
                    Label("Show on globe", systemImage: "location")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Camera")
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

struct SearchScreen: View {
    @ObservedObject private var store = GlobeStore.shared
    @Binding var tab: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationView {
            List(store.places) { place in
                Button {
                    Task {
                        await store.fly(lat: place.lat, lon: place.lon)
                        tab = 0
                        dismiss()
                    }
                } label: {
                    Text(place.name)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if store.busy && store.places.isEmpty { ProgressView() }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "City, address, or place")
            .onSubmit(of: .search) { Task { await store.search(query) } }
        }
        .navigationViewStyle(.stack)
    }
}

struct SettingsScreen: View {
    @ObservedObject private var store = GlobeStore.shared
    @State private var draft = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://your-server.example", text: $draft)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                    Button("Save UPLINK") { Task { await store.saveUplink(draft) } }
                    Button("Use public feeds") { Task { await store.saveUplink("") } }
                } header: {
                    Text("UPLINK")
                } footer: {
                    Text("Leave this empty to read public feeds on the phone. Keyed feeds need this URL.")
                }
                Section("Quality") {
                    Picker("Performance", selection: Binding(
                        get: { store.quality },
                        set: { level in Task { await store.saveQuality(level) } }
                    )) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)
                }
                if !store.status.isEmpty {
                    Section {
                        Text(store.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(.stack)
        .task {
            await store.loadSettings()
            if draft.isEmpty { draft = store.uplink }
        }
    }
}

struct EntitySheet: View {
    let pick: EntityPick
    @Binding var tab: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pick.title).font(.headline).lineLimit(3)
            if !pick.detail.isEmpty {
                Text(pick.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(8)
            }
            if let lat = pick.lat, let lon = pick.lon {
                Button {
                    Task {
                        await GlobeStore.shared.fly(lat: lat, lon: lon, range: 8000)
                        tab = 0
                        dismiss()
                    }
                } label: {
                    Label("Center", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .modifier(CompactDetent())
    }
}

struct MediumDetent: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}

private struct CompactDetent: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.height(240), .medium])
        } else {
            content
        }
    }
}
