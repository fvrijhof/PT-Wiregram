import SwiftUI
import Combine

struct GraphNode: Identifiable, Equatable {
    enum Kind: Equatable { case track, endpoint, deviceIn, deviceOut }
    let id: String
    let kind: Kind
    let name: String
    let typeLabel: String
    let color: Color
    let inactive: Bool
    let muted: Bool
    let soloed: Bool
    let index: Int
    var input: String?
    var outputs: [String] = []
    var sends: [String: String] = [:]
    var sendStates: [String: String] = [:]
    var groupIDs: [String] = []
    var groupNames: [String] = []
    var vcaNames: [String] = []
    var inserts: [String] = []
    var fromHiddenCache = false
    var objectPath: String?       // Dolby Atmos object assignment
    var objectActive: Bool?       // true = object receives the signal, false = bed/bus does
    var atmosGroup: String?
    var detail = ""            // extra subtitle (device info)
    var ptType = ""            // PTSL track type (TT_Audio, TT_Aux, …) or "collapsed"
    /// Collapsed block: the tracks it stands for.
    var memberNames: [String] = []
    /// Key of the collapse bucket this node is (or belongs to); nil when it can't be collapsed.
    var collapseKey: String?
    var isCollapsed: Bool { ptType == "collapsed" }
    var column = 0
    var row: Double = 0
}

struct GraphEdge: Identifiable, Equatable {
    let from: String
    let to: String
    let isSend: Bool
    let label: String
    var muted = false
    var isPre = false
    /// Assigned but not carrying signal (the other side of an Atmos bus/object toggle).
    var inactiveRoute = false
    /// How many original connections this edge stands for (after collapsing tracks).
    var count = 1
    var id: String { "\(from)>\(to)>\(isSend)>\(label)" }
}

struct TrackRow: Identifiable {
    let id: String
    let index: Int
    let name: String
    let type: String
    let input: String
    let output: String
    let sends: String
    let groups: String
    let inserts: String
    let vca: String
}

@MainActor
final class SessionModel: ObservableObject {
    // Raw state
    @Published private(set) var sessionName = ""
    @Published private(set) var ptslStatus = "Connecting…"
    @Published private(set) var ptslOK = false
    @Published private(set) var axTrusted = ProToolsAX.isTrusted
    @Published private(set) var axWindow = ""
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var tracks: [PTTrack] = []
    @Published private(set) var routing: [String: AXRouting] = [:]
    @Published private(set) var groups: [ProToolsAX.PTGroup] = []
    @Published private(set) var groupStatus = ""
    @Published private(set) var ioPaths: [String: IOPathInfo] = [:]
    var ioStatus: String {
        let i = ioPaths.values.filter { $0.direction == "Input" }.count
        let o = ioPaths.values.filter { $0.direction == "Output" }.count
        let a = ioPaths.values.filter { $0.direction == "Atmos" }.count
        if i == 0 && o == 0 && a == 0 { return "I/O: choose Read ▸ I/O Setup to read hardware paths" }
        return "I/O: \(i) inputs, \(o) outputs" + (a > 0 ? ", \(a) Atmos paths" : "")
    }

    // View options
    enum SendMode: String, CaseIterable { case all, selection, off }
    /// All send lines, only those of the selected/hovered track, or none.
    @Published var sendMode: SendMode = SendMode(rawValue: UserDefaults.standard.string(forKey: "sendMode") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(sendMode.rawValue, forKey: "sendMode"); if (sendMode == .off) != (oldValue == .off) { rebuild() } }
    }
    var showSends: Bool { sendMode != .off }

    /// Large sessions: merge source tracks into one block per routing / folder / group.
    enum CollapseMode: String, CaseIterable { case off, routing, folder, group }
    @Published var collapseMode: CollapseMode = CollapseMode(rawValue: UserDefaults.standard.string(forKey: "collapseMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(collapseMode.rawValue, forKey: "collapseMode"); expanded = []; rebuild() }
    }
    /// Collapse buckets the user opened up again.
    @Published private(set) var expanded: Set<String> = []
    func toggleCollapse(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        selectedID = nil; hoveredID = nil
        rebuild()
    }
    func collapseAll() { expanded = []; rebuild() }
    /// Set when the canvas was dragged (panned), so the click that ends it doesn't deselect.
    var lastPanEnd = Date.distantPast
    // What to show inside the blocks (each adds a line)
    @Published var showGroupNames = false
    @Published var showInserts = false
    @Published var showVCA = false
    @Published var splitPrePost = true
    var extraLines: Int { [showGroupNames, showInserts, showVCA].filter { $0 }.count }

    // Routing of hidden tracks, read on demand by temporarily unhiding them; remembered per session.
    @Published private(set) var hiddenRouting: [String: AXRouting] = [:]
    @Published private(set) var hiddenStatus = ""
    @Published private(set) var ioReadStatus = ""
    @Published var onlyRouted = true { didSet { rebuild() } }
    @Published var hideInactive = false { didSet { rebuild() } }
    @Published var hideHidden = true { didSet { rebuild() } }
    @Published var showDevices = false { didSet { rebuild() } }
    @Published var groupByGroups = false { didSet { rebuild() } }
    @Published var search = ""
    @Published var selectedID: String?
    /// Focus mode: only the complete routing around this node is shown (right-click a node).
    @Published var focusID: String? { didSet { if focusID != oldValue { selectedID = nil; rebuild() } } }
    @Published var hoveredID: String?

    /// Rows of blocks the user dragged, per view ("all" or a focus id); saved per session.
    @Published private(set) var rowOverrides: [String: [String: Double]] = [:]
    var layoutKey: String { focusID.map { "focus:" + $0 } ?? "all" }
    var hasRowOverrides: Bool { !(rowOverrides[layoutKey] ?? [:]).isEmpty }

    /// Moves a block within its column by `deltaRows` (snapped to quarter rows).
    func moveNode(_ id: String, byRows deltaRows: Double) {
        guard let n = nodes.first(where: { $0.id == id }) else { return }
        let new = max(0, ((n.row + deltaRows) * 4).rounded() / 4)
        rowOverrides[layoutKey, default: [:]][id] = new
        saveRowOverrides()
        rebuild()
    }

    func resetRowOverrides() {
        rowOverrides[layoutKey] = nil
        saveRowOverrides()
        rebuild()
    }

    private func saveRowOverrides() {
        if let d = try? JSONEncoder().encode(rowOverrides) { UserDefaults.standard.set(d, forKey: "rows:" + sessionName) }
    }
    var focusName: String { focusID.flatMap { id in nodes.first { $0.id == id }?.name } ?? "" }

    // Derived
    @Published private(set) var nodes: [GraphNode] = []
    @Published private(set) var edges: [GraphEdge] = []
    @Published private(set) var rows: [TrackRow] = []

    private let worker = PollWorker()
    private var lastSessionForGroups = ""
    private var timer: AnyCancellable?

    func start() {
        worker.onUpdate = { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        worker.start()
    }

    func refreshNow() { worker.forceRescan() }

    /// Reads Pro Tools group membership (read-only: selects tracks one by one via PTSL,
    /// reads the Group List indicators, then restores the original selection).
    // MARK: Reading from Pro Tools (briefly controls the Pro Tools UI)

    enum ReadKind { case groups, hidden, io }
    /// "Don't ask again" for the read notice: remembered only while the app runs.
    private var skipReadNotice = false

    /// Before PT Wiregram drives Pro Tools to read something: explain what will happen (unless the
    /// user said not to ask again this time) and make sure the session isn't playing.
    private func prepareRead(_ kind: ReadKind) -> Bool {
        if !skipReadNotice {
            let a = NSAlert()
            a.messageText = "PT Wiregram will briefly control Pro Tools"
            let what: String
            switch kind {
            case .groups: what = "To read the groups, PT Wiregram selects each track for a moment and then restores your selection."
            case .hidden: what = "To read the hidden tracks, PT Wiregram shows them for a moment, reads their routing and hides them again."
            case .io: what = "To read the I/O Setup, PT Wiregram opens Setup ▸ I/O, reads the Input and Output tabs and closes it with Cancel."
            }
            a.informativeText = what + "\n\nNothing in your session is changed, but it's a good idea to save your session first (⌘S). If the session is playing, playback is stopped first. Please don't use Pro Tools until reading is done."
            a.addButton(withTitle: "Continue")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don't ask again until PT Wiregram quits"
            guard a.runModal() == .alertFirstButtonReturn else { return false }
            if a.suppressionButton?.state == .on { skipReadNotice = true }
        }
        return ensureStopped()
    }

    /// Stops playback before reading. A running recording is never stopped by PT Wiregram.
    private func ensureStopped() -> Bool {
        let c = PTSLClient()
        guard let state = try? c.transportState(), !state.isEmpty else { return true }
        func running(_ s: String) -> Bool { !(s.contains("Stopped") || s.contains("Unknown")) }
        guard running(state) else { return true }
        if state.contains("Recording") {
            let a = NSAlert()
            a.messageText = "Pro Tools is recording"
            a.informativeText = "PT Wiregram doesn't read while Pro Tools records. Try again when the recording has stopped."
            a.runModal()
            return false
        }
        try? c.togglePlayState()
        for _ in 0..<30 {
            if let s = try? c.transportState(), !running(s) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let a = NSAlert()
        a.messageText = "Couldn't stop playback"
        a.informativeText = "Stop playback in Pro Tools and try again."
        a.runModal()
        return false
    }

    func readGroups() {
        guard prepareRead(.groups) else { return }
        groupStatus = "Reading groups…"
        let names = tracks.map(\.name)
        worker.readGroups(trackNames: names, progress: { [weak self] i, n in
            Task { @MainActor in self?.groupStatus = "Reading groups… \(i)/\(n)" }
        }) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let g):
                    self.groups = g
                    if let d = try? JSONEncoder().encode(g) { UserDefaults.standard.set(d, forKey: "groups:" + self.sessionName) }
                    self.groupStatus = "\(g.count) groups read"
                    if !g.isEmpty { self.groupByGroups = true }
                case .failure(let e):
                    self.groupStatus = "Failed: \(e.localizedDescription)"
                }
                self.rebuild()
            }
        }
    }

    /// Temporarily unhides the explicitly hidden tracks (official Pro Tools API), reads their
    /// routing from the Mix window and hides them again.
    func readHiddenTracks() {
        let names = tracks.filter { $0.isHidden && Self.routableTypes.contains($0.type) }.map(\.name)
        let unhide = tracks.filter(\.isHiddenExplicitly).map(\.name) // incl. hidden folders
        let openFolders = Self.closedAncestors(of: tracks.filter { $0.isHidden && Self.routableTypes.contains($0.type) }, in: tracks)
        guard !names.isEmpty, !unhide.isEmpty else { hiddenStatus = "No hidden tracks"; return }
        guard prepareRead(.hidden) else { return }
        hiddenStatus = "Reading hidden tracks…"
        worker.enqueueJob { [weak self] in
            let result = Result { try ProToolsAX.readHiddenRouting(ptsl: PTSLClient(), names: names, unhide: unhide, openFolders: openFolders) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.hiddenRouting = r
                    if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: "hidden:" + self.sessionName) }
                    self.hiddenStatus = "\(r.count) of \(names.count) hidden tracks read"
                case .failure(let e):
                    self.hiddenStatus = "Failed: \(e.localizedDescription)"
                }
                self.rebuild()
            }
        }
    }

    /// Opens Setup ▸ I/O, reads the Input and Output tabs and closes it again (Cancel).
    func readIO() {
        guard prepareRead(.io) else { return }
        ioReadStatus = "Reading I/O…"
        worker.enqueueJob { [weak self] in
            let result = Result { try ProToolsAX.readIOViaDialog() }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let io):
                    self.applyIO(io)
                    let i = io.values.filter { $0.direction == "Input" }.count, o = io.count - i
                    self.ioReadStatus = "I/O read: \(i) inputs, \(o) outputs"
                case .failure(let e):
                    self.ioReadStatus = "Failed: \(e.localizedDescription)"
                }
            }
        }
    }

    private func applyIO(_ io: [String: IOPathInfo]) {
        guard !io.isEmpty else { return }
        let dirs = Set(io.values.map(\.direction))
        let merged = ioPaths.filter { !dirs.contains($0.value.direction) }.merging(io) { _, n in n }
        if merged != ioPaths {
            ioPaths = merged
            if let d = try? JSONEncoder().encode(merged) { UserDefaults.standard.set(d, forKey: "io:" + sessionName) }
            rebuild()
        }
    }

    func requestAccessibility() {
        ProToolsAX.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// An old permission entry (from an earlier build with a different signature) can stay
    /// switched on in System Settings without working. This removes PT Wiregram's own entry,
    /// asks again and opens the settings, so the user can switch it on fresh.
    func resetAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "nl.wiregram.protools"]
        try? p.run()
        p.waitUntilExit()
        requestAccessibility()
    }

    /// Restarts the app (macOS sometimes only applies a new permission after a restart).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// The session has hidden tracks whose routing hasn't been read (Read ▸ Hidden Tracks).
    var hasUnreadHiddenTracks: Bool {
        hiddenRouting.isEmpty && tracks.contains { $0.isHidden && Self.routableTypes.contains($0.type) }
    }

    func injectGroups(_ g: [ProToolsAX.PTGroup]) { groups = g }
    func injectIO(_ io: [String: IOPathInfo]) { ioPaths = io }

    /// Test hook: inject data without Pro Tools UI access.
    func inject(tracks: [PTTrack], routing: [String: AXRouting]) {
        self.tracks = tracks; self.routing = routing; rebuild()
    }

    private func apply(_ s: PollWorker.Snapshot) {
        var changed = false
        if s.sessionName != sessionName { sessionName = s.sessionName }
        if s.ptslOK != ptslOK { ptslOK = s.ptslOK }
        if s.ptslStatus != ptslStatus { ptslStatus = s.ptslStatus }
        if s.axTrusted != axTrusted { axTrusted = s.axTrusted }
        if s.axWindow != axWindow { axWindow = s.axWindow }
        if let t = s.tracks, t != tracks { tracks = t; changed = true }
        if s.routing != routing { routing = s.routing; changed = true }
        if !s.ioPaths.isEmpty { applyIO(s.ioPaths) }
        if s.sessionName != lastSessionForGroups {
            // New session: load the groups we read for it before (if any).
            lastSessionForGroups = s.sessionName
            let saved = UserDefaults.standard.data(forKey: "groups:" + s.sessionName)
                .flatMap { try? JSONDecoder().decode([ProToolsAX.PTGroup].self, from: $0) } ?? []
            if saved != groups { groups = saved; groupStatus = saved.isEmpty ? "" : "\(saved.count) groups (read earlier)"; changed = true }
            let savedIO = UserDefaults.standard.data(forKey: "io:" + s.sessionName)
                .flatMap { try? JSONDecoder().decode([String: IOPathInfo].self, from: $0) } ?? [:]
            if savedIO != ioPaths { ioPaths = savedIO; changed = true }
            rowOverrides = UserDefaults.standard.data(forKey: "rows:" + s.sessionName)
                .flatMap { try? JSONDecoder().decode([String: [String: Double]].self, from: $0) } ?? [:]
            let savedHidden = UserDefaults.standard.data(forKey: "hidden:" + s.sessionName)
                .flatMap { try? JSONDecoder().decode([String: AXRouting].self, from: $0) } ?? [:]
            if savedHidden != hiddenRouting { hiddenRouting = savedHidden; hiddenStatus = savedHidden.isEmpty ? "" : "\(savedHidden.count) hidden tracks (read earlier)"; changed = true }
        }
        lastUpdate = Date()
        if changed || nodes.isEmpty { rebuild() }
    }

    // MARK: Graph construction

    static let routableTypes: Set<String> = ["TT_Audio", "TT_Aux", "TT_Instrument", "TT_Master", "TT_RoutingFolder", "TT_Unknown"]

    func rebuild() {
        let hiddenByName = Dictionary(hiddenRouting.map { (Self.normName($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        let routingByName = Dictionary(routing.map { (Self.normName($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        // 1. Track nodes (PTSL list, plus any strips AX found that PTSL didn't report)
        var trackNodes: [GraphNode] = []
        var known = Set<String>()
        for t in tracks where Self.routableTypes.contains(t.type) {
            if hideInactive && t.isInactive { continue }
            if hideHidden && t.isHidden { continue }
            known.insert(Self.normName(t.name))
            var n = GraphNode(id: "t:" + t.id, kind: .track, name: t.name, typeLabel: Self.typeLabel(t.type, t.format),
                              color: Color(argbHex: t.color), inactive: t.isInactive, muted: t.isMuted,
                              soloed: t.isSoloed, index: t.index)
            n.ptType = t.type
            if let r = routingByName[Self.normName(t.name)] ?? hiddenByName[Self.normName(t.name)] {
                n.input = r.input; n.outputs = r.outputs; n.sends = r.sends; n.sendStates = r.sendStates
                n.inserts = r.inserts
                n.objectPath = r.objectPath; n.objectActive = r.objectActive; n.atmosGroup = r.atmosGroup
                n.fromHiddenCache = routingByName[Self.normName(t.name)] == nil
            }
            let myGroups = groups.filter { g in g.members.contains(t.name) }
            n.groupIDs = myGroups.map(\.id)
            n.groupNames = myGroups.map(\.name)
            n.vcaNames = myGroups.compactMap { vcaOf($0) }.filter { $0 != t.name }
            trackNodes.append(n)
        }
        let hiddenNames = Set(tracks.filter { (hideInactive && $0.isInactive) || (hideHidden && $0.isHidden) }.map { Self.normName($0.name) })
        for (name, r) in routing where !known.contains(Self.normName(name)) && !hiddenNames.contains(Self.normName(name)) {
            var n = GraphNode(id: "ax:" + name, kind: .track, name: name, typeLabel: "Track", color: .gray,
                              inactive: false, muted: false, soloed: false, index: 10_000)
            n.input = r.input; n.outputs = r.outputs; n.sends = r.sends; n.sendStates = r.sendStates
            n.inserts = r.inserts
            trackNodes.append(n)
        }

        // 2. Who listens to which path? (inputs; master faders sit on their output path)
        var listeners: [String: [String]] = [:]
        for n in trackNodes {
            if let i = n.input, !i.isEmpty { listeners[Self.norm(i), default: []].append(n.id) }
            if n.typeLabel.hasPrefix("Master") { for o in n.outputs { listeners[Self.norm(o), default: []].append(n.id) } }
        }
        func targets(for path: String, from id: String) -> [String] {
            for candidate in Self.pathCandidates(path) {
                if let l = listeners[candidate] { return l.filter { $0 != id } }
            }
            return []
        }

        // 3. Edges + endpoint nodes
        var edgeList: [GraphEdge] = []
        var endpoints: [String: GraphNode] = [:]
        func connect(_ n: GraphNode, _ path: String, send: Bool, slot: String,
                     inactiveRoute: Bool = false, endpointType: String = "Output") {
            guard !path.isEmpty else { return }
            let label = send ? "\(slot): \(path)" : path
            let state = send ? (n.sendStates[slot] ?? "") : ""
            let muted = state.contains("muted") || state.contains("inactive")
            let isPre = send && state.contains("pre")
            let tg = targets(for: path, from: n.id)
            if tg.isEmpty {
                // Master fader feeding its own output path → endpoint; otherwise also endpoint.
                let eid = "e:" + Self.norm(path)
                if endpoints[eid] == nil {
                    endpoints[eid] = GraphNode(id: eid, kind: .endpoint, name: Self.displayPath(path), typeLabel: endpointType,
                                               color: .secondary, inactive: false, muted: false, soloed: false, index: 0)
                }
                edgeList.append(GraphEdge(from: n.id, to: eid, isSend: send, label: label, muted: muted, isPre: isPre, inactiveRoute: inactiveRoute))
            } else {
                for t in tg { edgeList.append(GraphEdge(from: n.id, to: t, isSend: send, label: label, muted: muted, isPre: isPre, inactiveRoute: inactiveRoute)) }
            }
        }
        for n in trackNodes {
            // Master faders are handled below: they always terminate in their output endpoint.
            if !n.typeLabel.hasPrefix("Master") {
                // Atmos: the bus (bed) outputs and the object are both drawn; the one the
                // Bus/Object toggle doesn't select is marked as an inactive route.
                let objectOn = n.objectActive == true
                for o in n.outputs { connect(n, o, send: false, slot: "", inactiveRoute: n.objectPath != nil && objectOn) }
                if let obj = n.objectPath {
                    connect(n, obj, send: false, slot: "", inactiveRoute: !objectOn, endpointType: "Atmos object")
                }
            }
            if showSends {
                for slot in n.sends.keys.sorted() { connect(n, n.sends[slot]!, send: true, slot: slot) }
            }
        }
        // A master fader's own output edge would point at itself → route master to its endpoint explicitly.
        for n in trackNodes where n.typeLabel.hasPrefix("Master") {
            for o in n.outputs {
                let eid = "e:" + Self.norm(o)
                if endpoints[eid] == nil {
                    endpoints[eid] = GraphNode(id: eid, kind: .endpoint, name: Self.displayPath(o), typeLabel: "Output",
                                               color: .secondary, inactive: false, muted: false, soloed: false, index: 0)
                }
                if !edgeList.contains(where: { $0.from == n.id && $0.to == eid }) {
                    edgeList.append(GraphEdge(from: n.id, to: eid, isSend: false, label: o))
                }
            }
        }

        // 4. Optional device layer: hardware inputs on the left, main output paths on the right.
        var devices: [String: GraphNode] = [:]
        if showDevices {
            var parentOf: [String: String] = [:]
            for r in routing.values { for (sub, parent) in r.outputParents { parentOf[Self.norm(sub)] = parent } }
            // Beds and objects feed the Dolby Atmos renderer (from the I/O Setup Atmos tab).
            let atmos = ioPaths.values.filter { $0.direction == "Atmos" }
            if let rendererName = atmos.first?.device {
                let rid = "d:renderer"
                let activeCount = atmos.filter(\.active).count
                for (eid, e) in endpoints {
                    guard Self.atmosPathKey(e.name, in: ioPaths) != nil else { continue }
                    if devices[rid] == nil {
                        var d = GraphNode(id: rid, kind: .deviceOut, name: rendererName, typeLabel: "Dolby Atmos Renderer",
                                          color: .secondary, inactive: false, muted: false, soloed: false, index: 0)
                        d.detail = "Dolby Atmos · \(activeCount) bed/object paths active"
                        devices[rid] = d
                    }
                    edgeList.append(GraphEdge(from: eid, to: rid, isSend: false, label: e.name))
                }
            }
            for (eid, e) in endpoints where !edgeList.contains(where: { $0.from == eid && $0.to == "d:renderer" }) {
                let key = Self.norm(e.name)
                // A sub-path ("7.1.4 out -> Output") feeds its main path; a main path is itself a device output.
                let main = parentOf[key] ?? (ioPaths["output:" + key] != nil ? e.name : nil)
                guard let main else { continue }
                let did = "d:" + Self.norm(main)
                if devices[did] == nil {
                    var d = GraphNode(id: did, kind: .deviceOut, name: main, typeLabel: "Output path",
                                      color: .secondary, inactive: false, muted: false, soloed: false, index: 0)
                    d.detail = ioPaths["output:" + Self.norm(main)]?.summary ?? "Hardware output"
                    devices[did] = d
                }
                if did != eid { edgeList.append(GraphEdge(from: eid, to: did, isSend: false, label: main)) }
            }
            // Hardware inputs come only from the Input tab of I/O Setup (a sub-path such as
            // "Mic in 1-2.L" belongs to its main path). Bus inputs are never shown here.
            for n in trackNodes {
                guard let i = n.input, !i.isEmpty,
                      let info = Self.pathCandidates(i).lazy.compactMap({ self.ioPaths["input:" + $0] }).first else { continue }
                let did = "i:" + Self.norm(info.name)
                if devices[did] == nil {
                    var d = GraphNode(id: did, kind: .deviceIn, name: info.name, typeLabel: "Input",
                                      color: .secondary, inactive: !info.active, muted: false, soloed: false, index: -1)
                    d.detail = info.summary
                    devices[did] = d
                }
                edgeList.append(GraphEdge(from: did, to: n.id, isSend: false, label: i))
            }
        }

        var all = trackNodes + endpoints.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if collapseMode != .off { collapse(&all, &edgeList) }
        if onlyRouted {
            let used = Set(edgeList.flatMap { [$0.from, $0.to] })
            all = all.filter { used.contains($0.id) }
        }

        if let f = focusID {
            if all.contains(where: { $0.id == f }) {
                let keep = Self.chain(of: f, in: edgeList)
                all = all.filter { keep.contains($0.id) }
                edgeList = edgeList.filter { keep.contains($0.from) && keep.contains($0.to) }
            } else {
                focusID = nil // focused node disappeared (filtered or deleted)
            }
        }

        layout(&all, edgeList)
        nodes = all
        edges = edgeList
        rows = trackNodes.sorted { $0.index < $1.index }.map { n in
            let sends = n.sends.keys.sorted().map { k in
                let st = n.sendStates[k].map { $0.isEmpty ? "" : " (\($0))" } ?? ""
                return "\(k) → \(n.sends[k]!)\(st)"
            }
            return TrackRow(id: n.id, index: n.index, name: n.name, type: n.typeLabel,
                            input: (n.input ?? "").isEmpty ? "—" : n.input!,
                            output: Self.outputText(n),
                            sends: sends.isEmpty ? "—" : sends.joined(separator: "   "),
                            groups: n.groupNames.isEmpty ? "—" : n.groupNames.joined(separator: ", "),
                            inserts: n.inserts.isEmpty ? "—" : n.inserts.joined(separator: " · "),
                            vca: n.vcaNames.isEmpty ? "—" : n.vcaNames.joined(separator: ", "))
        }
    }

    /// Bus/path an edge carries: the output path, or a send's path without its slot ("A: Rev" → "Rev").
    nonisolated static func busPath(_ e: GraphEdge) -> String {
        guard e.isSend, let r = e.label.range(of: ": ") else { return displayPath(e.label) }
        return displayPath(String(e.label[r.upperBound...]))
    }

    /// Replaces source tracks that share a bucket (same routing, folder or group) by one block.
    private func collapse(_ nodes: inout [GraphNode], _ edges: inout [GraphEdge]) {
        let kind = Dictionary(nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        // Only sources (tracks no other track feeds) are collapsed; buses stay visible.
        let fed = Set(edges.filter { kind[$0.from] == .track && $0.from != $0.to }.map(\.to))
        let trackByNodeID = Dictionary(tracks.map { ("t:" + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var signature: [String: [String]] = [:]
        for e in edges { signature[e.from, default: []].append("\(e.to)|\(e.isSend)|\(Self.norm(Self.busPath(e)))") }
        var buckets: [String: [Int]] = [:]
        for (i, n) in nodes.enumerated() where n.kind == .track && !fed.contains(n.id) && n.ptType != "TT_Master" {
            let key: String?
            switch collapseMode {
            case .routing:
                let sig = (signature[n.id] ?? []).sorted()
                key = sig.isEmpty ? nil : "r:" + sig.joined(separator: ";")
            case .folder:
                key = trackByNodeID[n.id].flatMap { $0.parentFolderID.isEmpty ? nil : "f:" + $0.parentFolderID }
            case .group:
                key = n.groupIDs.first.map { "g:" + $0 }
            case .off:
                key = nil
            }
            if let key { buckets[key, default: []].append(i) }
        }
        var replace: [String: String] = [:]   // member id → collapsed id
        var collapsed: [GraphNode] = []
        for (key, idx) in buckets where idx.count > 1 {
            if expanded.contains(key) {
                for i in idx { nodes[i].collapseKey = key }
                continue
            }
            let ms = idx.map { nodes[$0] }.sorted { $0.index < $1.index }
            let name: String
            switch collapseMode {
            case .folder: name = trackByID[String(key.dropFirst(2))]?.name ?? "Folder"
            case .group: name = groups.first { "g:" + $0.id == key }?.name ?? "Group"
            default: name = Self.rangeName(ms)
            }
            let cid = "c:" + key
            var c = GraphNode(id: cid, kind: .track, name: name, typeLabel: "\(ms.count) tracks", color: ms[0].color,
                              inactive: ms.allSatisfy(\.inactive), muted: ms.allSatisfy(\.muted),
                              soloed: ms.contains(where: \.soloed), index: ms[0].index)
            c.ptType = "collapsed"
            c.memberNames = ms.map(\.name)
            c.collapseKey = key
            c.groupIDs = ms[0].groupIDs; c.groupNames = ms[0].groupNames
            let inputs = Set(ms.compactMap(\.input))
            c.input = inputs.count == 1 ? inputs.first : (inputs.isEmpty ? nil : "\(inputs.count) inputs")
            c.outputs = Array(Set(ms.flatMap(\.outputs))).sorted()
            for m in ms { replace[m.id] = cid }
            collapsed.append(c)
        }
        guard !replace.isEmpty else { return }
        nodes.removeAll { replace[$0.id] != nil }
        nodes.append(contentsOf: collapsed)
        var merged: [GraphEdge] = []
        var at: [String: Int] = [:]
        for e in edges {
            let from = replace[e.from] ?? e.from, to = replace[e.to] ?? e.to
            if from == to && e.from != e.to { continue }
            let key = "\(from)>\(to)>\(e.isSend)>\(e.isPre)>\(e.inactiveRoute)>\(Self.norm(Self.busPath(e)))"
            if let i = at[key] {
                merged[i].count += 1
                merged[i].muted = merged[i].muted && e.muted
            } else {
                at[key] = merged.count
                merged.append(GraphEdge(from: from, to: to, isSend: e.isSend, label: e.label, muted: e.muted,
                                        isPre: e.isPre, inactiveRoute: e.inactiveRoute))
            }
        }
        edges = merged
    }

    /// Consecutive tracks "DX 1" … "DX 24" → "DX 1 … DX 24"; scattered ones → "DX 1, DX 4, …".
    static func rangeName(_ ms: [GraphNode]) -> String {
        guard let first = ms.first, let last = ms.last, ms.count > 1 else { return ms.first?.name ?? "" }
        let consecutive = zip(ms, ms.dropFirst()).allSatisfy { $1.index == $0.index + 1 }
        return consecutive ? "\(first.name) … \(last.name)" : "\(first.name), \(ms[1].name), …"
    }

    private func layout(_ nodes: inout [GraphNode], _ edges: [GraphEdge]) {
        let ids = Set(nodes.map(\.id))
        let es = edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        // Column placement:
        //  - sources (tracks nothing in the session feeds) sit in the first column;
        //  - every other track is placed by its distance to the outputs ("as late as possible"),
        //    so buses doing the same job (e.g. all downmixes feeding the same aux) line up.
        // Edges back into the current DFS stack (feedback loops) are ignored.
        let kindOf = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.kind) })
        var predIDs: [String: [String]] = [:]
        var succTracks: [String: [String]] = [:]
        for e in es where e.from != e.to && kindOf[e.from] != .deviceIn {
            predIDs[e.to, default: []].append(e.from)
            if kindOf[e.from] == .track && kindOf[e.to] == .track { succTracks[e.from, default: []].append(e.to) }
        }
        var heightMemo: [String: Int] = [:]
        var onStack = Set<String>()
        func height(_ id: String) -> Int {
            if let h = heightMemo[id] { return h }
            onStack.insert(id)
            var h = 0
            for t in succTracks[id] ?? [] where !onStack.contains(t) { h = max(h, height(t) + 1) }
            onStack.remove(id)
            heightMemo[id] = h
            return h
        }
        let trackIDs = nodes.filter { $0.kind == .track }.map(\.id)
        let isSource = Dictionary(uniqueKeysWithValues: trackIDs.map { id in
            (id, !(predIDs[id] ?? []).contains { kindOf[$0] == .track })
        })
        let nonSourceMax = trackIDs.filter { !(isSource[$0] ?? true) }.map(height).max() ?? 0
        var col: [String: Int] = [:]
        for id in trackIDs {
            col[id] = (isSource[id] ?? true) ? 0 : 1 + (nonSourceMax - height(id))
        }
        let maxTrackCol = nodes.filter { $0.kind == .track }.map { col[$0.id] ?? 0 }.max() ?? 0
        for i in nodes.indices where nodes[i].kind == .endpoint { col[nodes[i].id] = maxTrackCol + 1 }
        for i in nodes.indices where nodes[i].kind == .deviceOut { col[nodes[i].id] = maxTrackCol + 2 }
        if nodes.contains(where: { $0.kind == .deviceIn }) {
            for i in nodes.indices { col[nodes[i].id] = nodes[i].kind == .deviceIn ? 0 : (col[nodes[i].id] ?? 0) + 1 }
        }
        // Sort key for columns without placed inputs: Pro Tools group (optional), then session order.
        let groupRank = Dictionary(groups.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let indexOf = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.index) })
        var firstTarget: [String: Int] = [:]
        for e in es where kindOf[e.from] == .deviceIn { firstTarget[e.from] = min(firstTarget[e.from] ?? .max, indexOf[e.to] ?? .max) }
        func sortKey(_ n: GraphNode) -> (Int, Int) {
            let g = groupByGroups ? (n.groupIDs.compactMap { groupRank[$0] }.min() ?? groups.count) : 0
            return (g, n.kind == .deviceIn ? (firstTarget[n.id] ?? 0) : n.index)
        }

        // Vertical placement: sources in session order; every later column is placed near its
        // inputs (weighted: an output pulls harder than a send), then refined so blocks also sit
        // near where they go, and stay out of the way of lines that pass through their column.
        var rowOf: [String: Double] = [:]
        let maxCol = col.values.max() ?? 0
        var preds: [String: [(String, Double)]] = [:], succs: [String: [(String, Double)]] = [:]
        for e in es where kindOf[e.from] != .deviceIn && e.from != e.to {
            let w: Double = e.isSend ? 1 : 3
            preds[e.to, default: []].append((e.from, w))
            succs[e.from, default: []].append((e.to, w))
        }
        let overrides = rowOverrides[layoutKey] ?? [:]

        /// Least-squares fit of `want` that keeps the order and the heights (pool adjacent violators).
        func fit(_ want: [Double], _ h: [Double]) -> [Double] {
            var off: [Double] = [], acc = 0.0
            for x in h { off.append(acc); acc += x }
            var blocks: [(sum: Double, n: Int)] = []
            for (i, w) in want.enumerated() {
                blocks.append((w - off[i], 1))
                while blocks.count > 1 {
                    let b = blocks[blocks.count - 1], a = blocks[blocks.count - 2]
                    guard a.sum / Double(a.n) > b.sum / Double(b.n) else { break }
                    blocks.removeLast(2); blocks.append((a.sum + b.sum, a.n + b.n))
                }
            }
            var out: [Double] = []
            for b in blocks { out += Array(repeating: b.sum / Double(b.n), count: b.n) }
            return out.enumerated().map { $0.element + off[$0.offset] }
        }
        /// Places a column's items (real blocks and passing lines) without overlap; blocks the
        /// user dragged keep their row, the others flow around them.
        func place(_ items: [(id: String?, want: Double, h: Double)]) {
            let fixed = items.compactMap { it in it.id.flatMap { id in overrides[id].map { (id, $0) } } }
            for (id, r) in fixed { rowOf[id] = r }
            let free = items.filter { $0.id == nil || overrides[$0.id!] == nil }
            let ys = fit(free.map(\.want), free.map(\.h))
            var next = 0.0
            for (k, it) in free.enumerated() {
                var y = max(ys[k], next)
                var moved = true
                while moved {
                    moved = false
                    for (_, o) in fixed where y < o + 1 && y + it.h > o { y = o + 1; moved = true }
                }
                if let id = it.id { rowOf[id] = y }
                next = y + it.h
            }
        }
        func mean(_ list: [(String, Double)]?) -> (Double, Double)? {
            let p = (list ?? []).compactMap { pair in rowOf[pair.0].map { ($0, pair.1) } }
            let w = p.reduce(0) { $0 + $1.1 }
            return w > 0 ? (p.reduce(0) { $0 + $1.0 * $1.1 } / w, w) : nil
        }
        let sourceCols = Set((0...maxCol).filter { c in
            nodes.filter { col[$0.id] == c }.allSatisfy { (preds[$0.id] ?? []).isEmpty }
        })
        for c in sourceCols.sorted() {
            // Source column: session (or group) order, with a gap between groups.
            var y = 0.0
            var lastGroup: Int?
            var items: [(id: String?, want: Double, h: Double)] = []
            for n in nodes.filter({ col[$0.id] == c }).sorted(by: { sortKey($0) < sortKey($1) }) {
                let g = sortKey(n).0
                if groupByGroups, let lg = lastGroup, lg != g { y += 0.6 }
                lastGroup = g
                items.append((n.id, y, 1))
                y += 1
            }
            place(items)
        }
        func placeColumn(_ c: Int, refine: Bool) {
            let colNodes = nodes.filter { col[$0.id] == c }
            var items: [(id: String?, want: Double, h: Double)] = colNodes.map { n in
                let p = mean(preds[n.id])
                var want = p?.0 ?? rowOf[n.id] ?? 0
                if refine, let s = mean(succs[n.id]) {
                    // Near the source first; where it goes counts for a third.
                    let pw = (p?.1 ?? 0) * 2
                    want = ((p?.0 ?? 0) * pw + s.0 * s.1) / (pw + s.1)
                }
                return (n.id, want, 1)
            }
            if refine {
                // Lines that pass this column reserve a little room, so blocks don't sit on them.
                var seen = Set<String>()
                for e in es where kindOf[e.from] != .deviceIn {
                    guard let a = col[e.from], let b = col[e.to], a < c, c < b,
                          let ra = rowOf[e.from], let rb = rowOf[e.to] else { continue }
                    let y = ra + (rb - ra) * Double(c - a) / Double(b - a)
                    guard seen.insert(e.to + "|" + String(Int((y * 2).rounded()))).inserted else { continue }
                    items.append((nil, y - 0.25, 0.5))
                }
            }
            let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.index) })
            items.sort { a, b in
                a.want == b.want ? (a.id.flatMap { index[$0] } ?? -1) < (b.id.flatMap { index[$0] } ?? -1) : a.want < b.want
            }
            place(items)
        }
        let flowCols = (0...maxCol).filter { !sourceCols.contains($0) }
        for c in flowCols { placeColumn(c, refine: false) }
        for _ in 0..<2 {
            for c in flowCols.reversed() { placeColumn(c, refine: true) }
            for c in flowCols { placeColumn(c, refine: true) }
        }
        for i in nodes.indices {
            nodes[i].column = col[nodes[i].id] ?? 0
            nodes[i].row = rowOf[nodes[i].id] ?? 0
        }
    }

    /// IDs connected (upstream + downstream) to the selection, for highlighting.
    func chain(of id: String) -> Set<String> { Self.chain(of: id, in: edges) }

    static func chain(of id: String, in edges: [GraphEdge]) -> Set<String> {
        var result: Set<String> = [id]
        var down = [id], up = [id]
        while let x = down.popLast() {
            for e in edges where e.from == x && !result.contains(e.to) { result.insert(e.to); down.append(e.to) }
        }
        var seenUp: Set<String> = [id]
        while let x = up.popLast() {
            for e in edges where e.to == x && !seenUp.contains(e.from) { seenUp.insert(e.from); result.insert(e.from); up.append(e.from) }
        }
        return result
    }

    /// VCA controlling a group: from the Group List title ("DX group (DX VCA)") or from a VCA
    /// strip's "Group Assignment selector".
    func vcaOf(_ g: ProToolsAX.PTGroup) -> String? {
        if let v = g.vca, !v.isEmpty { return v }
        return routing.first { $0.value.vcaGroup == g.name }?.key
    }

    struct VCAInfo: Identifiable {
        let id: String
        let name: String
        let color: Color
        let groups: [String]
        let members: [PTTrack]
        let nestedVCAs: [String]
    }

    /// VCA tracks with the tracks they control (via their groups).
    var vcaInfos: [VCAInfo] {
        let vcaTracks = tracks.filter { $0.type == "TT_Vca" }
        let byName = Dictionary(tracks.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return vcaTracks.map { v in
            let gs = groups.filter { vcaOf($0) == v.name }
            let names = Set(gs.flatMap(\.members)).subtracting([v.name])
            let members = names.compactMap { byName[$0] }.sorted { $0.index < $1.index }
            return VCAInfo(id: v.id, name: v.name, color: Color(argbHex: v.color), groups: gs.map(\.name),
                           members: members.filter { $0.type != "TT_Vca" },
                           nestedVCAs: members.filter { $0.type == "TT_Vca" }.map(\.name))
        }
    }

    /// Audio/aux/instrument tracks that no VCA controls.
    var tracksWithoutVCA: [PTTrack] {
        let controlled = Set(vcaInfos.flatMap { $0.members.map(\.name) })
        return tracks.filter { ["TT_Audio", "TT_Aux", "TT_Instrument", "TT_RoutingFolder"].contains($0.type) && !controlled.contains($0.name) }
            .filter { !(hideInactive && $0.isInactive) && !(hideHidden && $0.isHidden) }
    }

    /// Closed folders (at any level) that contain one of `targets`.
    nonisolated static func closedAncestors(of targets: [PTTrack], in all: [PTTrack]) -> [String] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for t in targets {
            var pid = t.parentFolderID
            var guardCount = 0
            while !pid.isEmpty, let p = byID[pid], guardCount < 20 {
                if !p.isOpen && !out.contains(p.name) { out.append(p.name) }
                pid = p.parentFolderID; guardCount += 1
            }
        }
        return out
    }

    /// Finds the Atmos renderer path for a bed/object name. A mono object such as "Object 15"
    /// is one half of the renderer path "Object 15-16".
    static func atmosPathKey(_ name: String, in io: [String: IOPathInfo]) -> String? {
        for c in pathCandidates(name) where io["atmos:" + c] != nil { return "atmos:" + c }
        let n = norm(name)
        guard let r = n.range(of: #"(\d+)$"#, options: .regularExpression), let num = Int(n[r]) else { return nil }
        let prefix = n[..<r.lowerBound]
        for key in io.keys where key.hasPrefix("atmos:" + prefix) {
            let rest = key.dropFirst(("atmos:" + prefix).count)
            let parts = rest.split(separator: "-").compactMap { Int($0) }
            if parts.count == 2, (parts[0]...parts[1]).contains(num) { return key }
        }
        return nil
    }

    static func outputText(_ n: GraphNode) -> String {
        var parts = n.outputs
        if let o = n.objectPath {
            let on = n.objectActive == true
            parts = parts.map { on ? "\($0) (inactive)" : "\($0) [BED active]" }
            parts.append(on ? "\(o) [OBJ active]" : "\(o) (inactive)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    // MARK: Helpers

    /// Normalises a path name for matching: drops Pro Tools' prefix markers
    /// ("+ " = multiple outputs, "< "/"> " = down/upmix), case and repeated spaces.
    nonisolated static func normStatic(_ p: String) -> String { norm(p) }

    nonisolated static func norm(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        while let f = s.first, "+<>".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        return normName(s)
    }

    nonisolated static func normName(_ n: String) -> String {
        n.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// The path itself, then its parent paths: "FX Aux.5.0" → "fx aux.5", "fx aux";
    /// "MX Aux 5.0" → "mx aux"; "Bus.L" → "bus".
    static func pathCandidates(_ p: String) -> [String] {
        let n = norm(p)
        var out = [n]
        var s = n
        while let dot = s.lastIndex(of: ".") {
            s = String(s[..<dot]); if !s.isEmpty { out.append(s) }
        }
        if let r = n.range(of: #"[ .](\d(\.\d){1,2}|l|r|c|ls|rs|lfe)$"#, options: .regularExpression) {
            out.append(String(n[..<r.lowerBound]))
        }
        return out
    }

    nonisolated static func displayPath(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        while let f = s.first, "+<>".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }

    static func typeLabel(_ t: String, _ f: String) -> String {
        let base: String
        switch t {
        case "TT_Audio": base = "Audio"
        case "TT_Aux": base = "Aux"
        case "TT_Instrument": base = "Instrument"
        case "TT_Master": base = "Master"
        case "TT_RoutingFolder": base = "Routing Folder"
        default: base = "Track"
        }
        let fmt: String
        switch f {
        case "TF_Mono": fmt = "Mono"
        case "TF_Stereo": fmt = "Stereo"
        case "": fmt = ""
        default: fmt = f.replacingOccurrences(of: "TF_", with: "").replacingOccurrences(of: "_", with: ".")
        }
        return fmt.isEmpty || fmt == "None" || fmt == "Unknown" ? base : "\(base) · \(fmt)"
    }
}

// MARK: - Background polling

final class PollWorker {
    struct Snapshot {
        var sessionName = ""
        var ptslOK = false
        var ptslStatus = ""
        var axTrusted = false
        var axWindow = ""
        var tracks: [PTTrack]?
        var routing: [String: AXRouting] = [:]
        var ioPaths: [String: IOPathInfo] = [:]
    }

    var onUpdate: ((Snapshot) -> Void)?
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    private let ptsl = PTSLClient()
    private let ax = ProToolsAX()
    private var tick = 0
    private var lastTracks: [PTTrack]?
    private var lastName = ""
    private var ptslOK = false
    private var ptslStatus = "Connecting…"
    private var rescanRequested = false

    func start() {
        let t = Thread { self.loop() }
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func enqueue(_ job: @escaping () -> Void) { lock.lock(); jobs.append(job); lock.unlock() }

    func enqueueJob(_ job: @escaping () -> Void) { enqueue(job) }

    func readGroups(trackNames: [String], progress: @escaping (Int, Int) -> Void,
                    _ done: @escaping (Result<[ProToolsAX.PTGroup], Error>) -> Void) {
        enqueue { done(Result { try ProToolsAX.readGroups(ptsl: self.ptsl, trackNames: trackNames, progress: progress) }) }
    }

    func forceRescan() { enqueue { self.rescanRequested = true; self.tick = 0 } }

    private func loop() {
        while true {
            autoreleasepool { step() }
            Thread.sleep(forTimeInterval: 0.75)
        }
    }

    private func step() {
        lock.lock(); let pending = jobs; jobs = []; lock.unlock()
        pending.forEach { $0() }
        // PTSL track list every ~2s (cheap on localhost, but no need to hammer Pro Tools).
        if tick % 3 == 0 {
            if ProToolsAX.proToolsPID == nil {
                ptslOK = false; ptslStatus = "Pro Tools is not running"; lastTracks = []; lastName = ""
            } else {
                do {
                    lastName = try ptsl.sessionName()
                    lastTracks = try ptsl.trackList()
                    ptslOK = true; ptslStatus = "PTSL connected"
                } catch {
                    ptslOK = false; ptslStatus = error.localizedDescription
                    lastTracks = []
                }
            }
        }
        tick += 1

        var snap = Snapshot()
        snap.sessionName = lastName
        snap.ptslOK = ptslOK
        snap.ptslStatus = ptslStatus
        snap.tracks = lastTracks
        snap.axTrusted = ProToolsAX.isTrusted
        if snap.axTrusted {
            snap.routing = ax.readRouting(forceRescan: rescanRequested)
            rescanRequested = false
            snap.axWindow = ax.windowUsed
            if tick % 4 == 0 { snap.ioPaths = ProToolsAX.readIOSetup() }
        }
        onUpdate?(snap)
    }
}

extension Color {
    /// "#AARRGGBB" (PTSL) or "#RRGGBB"
    init(argbHex: String) {
        var s = argbHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 8 { s.removeFirst(2) }
        let v = UInt32(s, radix: 16) ?? 0x808080
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}


/// Hardware info for a main I/O path, read from Pro Tools' I/O Setup window when it is open.
struct IOPathInfo: Equatable, Codable {
    var name: String
    var direction: String // "Input" or "Output"
    var format: String
    var device: String
    var channels: String
    var active: Bool
    var summary: String {
        var parts = [format, device].filter { !$0.isEmpty }
        if !channels.isEmpty { parts.append("ch \(channels)") }
        if !active { parts.append("inactive") }
        return parts.isEmpty ? "Hardware" : parts.joined(separator: " · ")
    }
}
