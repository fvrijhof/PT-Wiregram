import SwiftUI

enum Layout {
    static let nodeW: CGFloat = 210
    static let nodeH: CGFloat = 34
    static let colGap: CGFloat = 130
    static let rowGap: CGFloat = 10
    static let pad: CGFloat = 30

    static let infoLineH: CGFloat = 12
    static func nodeHeight(extraLines: Int) -> CGFloat { nodeH + CGFloat(extraLines) * infoLineH }

    static func frame(_ n: GraphNode, gap: CGFloat = colGap, h: CGFloat = nodeH) -> CGRect {
        CGRect(x: pad + CGFloat(n.column) * (nodeW + gap),
               y: pad + 26 + CGFloat(n.row) * (h + rowGap),
               width: nodeW, height: h)
    }
}

/// View preferences shared by the toolbar menu and the graph (stored in UserDefaults).
enum Pref {
    static let legend = "showLegend"
    static let trackFill = "trackFill"      // "stripe" or "full"
    static let busNames = "showBusNames"
    static let bundle = "bundleLines"
    static let minimap = "showMinimap"
}

struct ContentView: View {
    @EnvironmentObject var model: SessionModel
    @State private var tab = 0
    @State private var zoom: CGFloat = 1.0
    @State private var tableScale: CGFloat = 1.0
    @State private var handTool = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(Pref.legend) private var showLegend = true
    @AppStorage(Pref.trackFill) private var trackFill = "stripe"
    @AppStorage(Pref.busNames) private var showBusNames = false
    @AppStorage(Pref.bundle) private var bundleLines = true
    @AppStorage(Pref.minimap) private var showMinimap = true
    @State private var scrollMonitor: Any?
    @State private var dismissedNotices: Set<String> = []
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 0) {
            if !model.axTrusted { accessBanner }
            ForEach(unreadNotices, id: \.key) { readNotice($0) }
            if case .ready(let v) = updater.state { updateBanner(v) }
            Group {
                switch tab {
                case 0: GraphView(zoom: $zoom, handTool: $handTool)
                case 1: TableView(scale: tableScale)
                default: VCAView(scale: tableScale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: installScrollZoom)
            .onAppear { Appearance.apply(appearance) }
            .onChange(of: appearance) { Appearance.apply($0) }
            .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }
            Divider()
            statusBar
        }
        .navigationTitle(model.sessionName.isEmpty ? "PT Wiregram" : model.sessionName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("", selection: $tab) {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(0)
                    Label("Table", systemImage: "tablecells").tag(1)
                    Label("VCAs", systemImage: "slider.vertical.3").tag(2)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Toggle(isOn: $model.onlyRouted) { Label("Routed Only", systemImage: "line.3.horizontal.decrease.circle") }
                    .labelStyle(.titleAndIcon)
                    .help("Hide tracks without routing information")
                Toggle(isOn: $model.hideInactive) { Label("Hide Inactive", systemImage: "moon.zzz") }
                    .labelStyle(.titleAndIcon)
                    .help("Hide inactive tracks")
                Toggle(isOn: Binding(get: { !model.hideHidden }, set: { model.hideHidden = !$0 })) {
                    Label("Show Hidden", systemImage: "eye.slash")
                }
                .labelStyle(.titleAndIcon)
                .help("Show hidden tracks. Their routing comes from ‘Read ▸ Hidden Tracks’.")
                Toggle(isOn: $model.showDevices) { Label("I/O Devices", systemImage: "cable.connector") }
                    .labelStyle(.titleAndIcon)
                    .help("Show hardware inputs (Input tab of I/O Setup) and output paths. Read the I/O via ‘Read ▸ I/O Setup’.")
                viewMenu
                Menu {
                    Button("Groups…") { model.readGroups() }
                    if !model.groupStatus.isEmpty { Text(model.groupStatus) }
                    Divider()
                    Button("Hidden Tracks…") { model.readHiddenTracks() }
                    if !model.hiddenStatus.isEmpty { Text(model.hiddenStatus) }
                    Divider()
                    Button("I/O Setup…") { model.readIO() }
                    if !model.ioReadStatus.isEmpty { Text(model.ioReadStatus) }
                } label: { Label("Read", systemImage: "square.and.arrow.down.on.square") }
                    .labelStyle(.titleAndIcon)
                    .help("Groups: briefly selects each track via the Pro Tools API and restores your selection. Hidden tracks: briefly shows them, reads their routing and hides them again. I/O: opens Setup ▸ I/O, reads the Input and Output tabs and closes it with Cancel. Everything is remembered per session.")
                if tab == 0 {
                    Toggle(isOn: $handTool) { Label("Hand Tool", systemImage: "hand.raised") }
                        .help("Hand tool: drag to move through the graph. You can also drag on an empty spot, hold Space while dragging, or drag with the middle mouse button.")
                    Button { zoom = max(0.2, zoom - 0.15) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    Button { zoom = min(3.0, zoom + 0.15) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                }
                Button { model.refreshNow() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan the Mix window")
            }
        }
        .searchable(text: $model.search, prompt: "Search track or bus")
    }

    private var viewMenu: some View {
        Menu {
            Picker("Send Lines", selection: $model.sendMode) {
                Text("All").tag(SessionModel.SendMode.all)
                Text("Only for Selected Track").tag(SessionModel.SendMode.selection)
                Text("Hidden").tag(SessionModel.SendMode.off)
            }
            Toggle("Distinguish Pre- and Post-Fader Sends", isOn: $model.splitPrePost).disabled(!model.showSends)
            Toggle("Bundle Lines per Bus", isOn: $bundleLines).disabled(showBusNames)
            Toggle("Show Bus Names", isOn: $showBusNames)
            Divider()
            Picker("Collapse Tracks", selection: $model.collapseMode) {
                Text("Off").tag(SessionModel.CollapseMode.off)
                Text("With Identical Routing").tag(SessionModel.CollapseMode.routing)
                Text("By Folder").tag(SessionModel.CollapseMode.folder)
                Text("By Group").tag(SessionModel.CollapseMode.group)
            }
            Button("Collapse All Again") { model.collapseAll() }.disabled(model.collapseMode == .off || model.expanded.isEmpty)
            Toggle("Arrange Sources by Group", isOn: $model.groupByGroups)
            Button("Reset Block Positions") { model.resetRowOverrides() }.disabled(!model.hasRowOverrides)
            Divider()
            Picker("Track Color", selection: $trackFill) {
                Text("Color Stripe").tag("stripe")
                Text("Full Block").tag("full")
            }
            Toggle("Show Legend", isOn: $showLegend)
            Toggle("Show Minimap", isOn: $showMinimap)
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Divider()
            Text("Show in Blocks")
            Toggle("Group Names", isOn: $model.showGroupNames)
            Toggle("Inserts", isOn: $model.showInserts)
            Toggle("VCA Assignment", isOn: $model.showVCA)
        } label: { Label("View", systemImage: "slider.horizontal.3") }
            .labelStyle(.titleAndIcon)
    }

    /// Option + scroll wheel zooms: the graph around the mouse pointer, the table's text size.
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.option) else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            guard delta != 0 else { return nil }
            let factor = exp(delta * 0.01)
            if tab != 0 {
                tableScale = min(2.5, max(0.6, tableScale * factor))
                return nil
            }
            let old = zoom
            let new = min(3.0, max(0.2, old * factor))
            guard new != old, let window = event.window else { return nil }
            // Keep the point under the pointer fixed while zooming.
            let hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil))
            let sv = hit?.enclosingScrollView
            let clip = sv?.contentView
            let pDoc = sv?.documentView?.convert(event.locationInWindow, from: nil)
            let origin = clip?.bounds.origin
            zoom = new
            if let sv, let clip, let pDoc, let origin, let doc = sv.documentView, doc.isFlipped {
                DispatchQueue.main.async {
                    let r = new / old
                    var o = NSPoint(x: pDoc.x * r - (pDoc.x - origin.x), y: pDoc.y * r - (pDoc.y - origin.y))
                    let maxX = max(0, doc.frame.width - clip.bounds.width), maxY = max(0, doc.frame.height - clip.bounds.height)
                    o.x = min(max(0, o.x), maxX); o.y = min(max(0, o.y), maxY)
                    clip.scroll(to: o)
                    sv.reflectScrolledClipView(clip)
                }
            }
            return nil
        }
    }

    // MARK: Notices for data that still has to be read from the session

    struct Notice { let key: String; let text: String; let status: String; let read: () -> Void }

    /// A function is switched on that needs something PT Wiregram hasn't read from this session
    /// yet (groups, hidden tracks, I/O setup): say so, with a button to read it now.
    private var unreadNotices: [Notice] {
        var out: [Notice] = []
        let session = model.sessionName
        func add(_ kind: String, _ text: String, _ status: String, _ read: @escaping () -> Void) {
            let key = kind + "|" + session
            if !dismissedNotices.contains(key) { out.append(Notice(key: key, text: text, status: status, read: read)) }
        }
        var needGroups: [String] = []
        if model.showGroupNames { needGroups.append("group names") }
        if model.showVCA { needGroups.append("VCA assignment") }
        if tab == 2 { needGroups.append("the VCA overview") }
        if model.collapseMode == .group { needGroups.append("collapsing by group") }
        if model.groupByGroups { needGroups.append("arranging by group") }
        if !needGroups.isEmpty && model.groups.isEmpty {
            add("groups", "The groups of this session haven't been read yet, so \(needGroups.joined(separator: ", ")) can't be shown.",
                model.groupStatus, model.readGroups)
        }
        if !model.hideHidden && model.hasUnreadHiddenTracks {
            add("hidden", "The routing of hidden tracks hasn't been read yet, so they are shown without connections.",
                model.hiddenStatus, model.readHiddenTracks)
        }
        if model.showDevices && model.ioPaths.isEmpty {
            add("io", "The I/O Setup hasn't been read yet, so hardware inputs and output paths can't be shown.",
                model.ioReadStatus, model.readIO)
        }
        return out
    }

    private func readNotice(_ n: Notice) -> some View {
        let busy = n.status.hasPrefix("Reading")
        return HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.text)
                if !n.status.isEmpty { Text(n.status).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) } else { Button("Read Now") { n.read() } }
            Button { dismissedNotices.insert(n.key) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide this message for this session")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }

    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            Text("PT Wiregram \(version) has been downloaded. It installs when you quit the app.")
            Spacer()
            Button("Relaunch to Update") { updater.relaunchToUpdate() }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
    }

    private var accessBanner: some View {
        HStack {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("PT Wiregram needs Accessibility access to read the I/O and send routing from the Pro Tools Mix window.")
                Text("Switched it on and still see this? Click Reset Permission, switch PT Wiregram on again, then Relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant Access…") { model.requestAccessibility() }
            Button("Reset Permission…") { model.resetAccessibility() }
                .help("Removes PT Wiregram's (possibly outdated) entry from Privacy & Security ▸ Accessibility and asks again")
            Button("Relaunch") { model.relaunch() }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle().fill(model.ptslOK ? .green : .red).frame(width: 8, height: 8)
            Text(model.ptslStatus).lineLimit(1)
            Divider().frame(height: 12)
            Circle().fill(model.axTrusted ? (model.axWindow.isEmpty ? .orange : .green) : .red).frame(width: 8, height: 8)
            Text(axText).lineLimit(1)
            Spacer()
            if model.showDevices { Text(model.ioStatus).lineLimit(1); Divider().frame(height: 12) }
            Text("\(model.tracks.count) tracks · \(model.nodes.count) blocks · \(model.edges.count) connections")
            if let d = model.lastUpdate { Text(d, style: .time).monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var axText: String {
        if !model.axTrusted { return "No Accessibility access" }
        if model.axWindow.isEmpty { return "Open the Mix window in Pro Tools (⌘=)" }
        return "Routing from: \(model.axWindow)"
    }
}

// MARK: - Graph

/// State of a hand-tool drag (a class so the event monitor can update it).
final class PanState {
    var scrollView: NSScrollView?
    var last = NSPoint.zero
    var swallowed = false
    var moved = false
    var space = false
    /// The pointer is over the minimap or legend: those handle the mouse themselves.
    var overOverlay = false
}

struct GraphView: View {
    @EnvironmentObject var model: SessionModel
    @Environment(\.colorScheme) private var scheme
    @Binding var zoom: CGFloat
    @Binding var handTool: Bool
    @AppStorage(Pref.legend) private var showLegend = true
    @AppStorage(Pref.trackFill) private var trackFill = "stripe"
    @AppStorage(Pref.busNames) private var showBusNames = false
    @AppStorage(Pref.bundle) private var bundleLines = true
    @AppStorage(Pref.minimap) private var showMinimap = true
    /// Not a @StateObject on purpose: scrolling should redraw only the minimap, not the graph.
    @State private var tracker = ScrollTracker()
    @GestureState private var pinch: CGFloat = 1
    @State private var zoomBeforeFocus: CGFloat?
    @State private var monitor: Any?
    @State private var panMonitor: Any?
    @State private var pan = PanState()

    /// Bus names are drawn where the lines of one bus come together, so they imply bundling.
    private var bundle: Bool { bundleLines || showBusNames }
    private var colGap: CGFloat {
        // Focus mode draws exactly like the full view (rails, bundling, highlighting).
        Layout.colGap + (bundle ? 50 : 0) + (showBusNames ? 90 : 0)
    }

    var body: some View {
        let hl = model.selectedID ?? model.hoveredID
        let lit: Set<String>? = hl.map { model.chain(of: $0) }
        let z = zoom * pinch

        if model.nodes.isEmpty {
            EmptyStateView()
        } else {
            let content = GraphContent(nodes: model.nodes, edges: model.edges,
                                       groups: model.groupByGroups && model.focusID == nil ? model.groups : [],
                                       colGap: colGap,
                                       showGroupNames: model.showGroupNames, showInserts: model.showInserts,
                                       showVCA: model.showVCA, splitPrePost: model.splitPrePost,
                                       scale: z, lit: lit,
                                       query: model.search, selectedID: model.selectedID ?? model.focusID,
                                       onHover: { id, on in
                                           if on { model.hoveredID = id } else if model.hoveredID == id { model.hoveredID = nil }
                                       },
                                       onTap: { id in model.selectedID = model.selectedID == id ? nil : id },
                                       onMove: { id, rows in model.moveNode(id, byRows: rows) },
                                       sendMode: model.sendMode,
                                       bundle: bundle, showBusNames: showBusNames,
                                       fullColor: trackFill == "full",
                                       onToggleCollapse: { model.toggleCollapse($0) })
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        content
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // A click that ends a pan of the canvas keeps the selection.
                                if Date().timeIntervalSince(model.lastPanEnd) > 0.3 { model.selectedID = nil }
                            }
                            // In focus mode, centre the (fitted) routing in the window.
                            .frame(minWidth: model.focusID == nil ? 0 : geo.size.width,
                                   minHeight: model.focusID == nil ? 0 : geo.size.height)
                            .id("graph-origin")
                            .background(ScrollFinder(tracker: tracker))
                    }
                    .onChange(of: model.focusID) { f in
                        if f != nil {
                            if zoomBeforeFocus == nil { zoomBeforeFocus = zoom }
                            withAnimation(.easeInOut(duration: 0.25)) { zoom = fitZoom(currentSize, in: geo.size) }
                        } else if let z0 = zoomBeforeFocus {
                            withAnimation(.easeInOut(duration: 0.25)) { zoom = z0 }
                            zoomBeforeFocus = nil
                        }
                        proxy.scrollTo("graph-origin", anchor: .topLeading)
                    }
                    .onChange(of: geo.size) { s in
                        // Keep the focused routing fitted when the window is resized.
                        if model.focusID != nil { zoom = fitZoom(currentSize, in: s) }
                    }
                }
            }
            .gesture(MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { zoom = min(3.0, max(0.2, zoom * $0)) })
            .onContinuousHover { phase in
                if case .active = phase, handTool || pan.space, !pan.overOverlay {
                    (pan.scrollView != nil ? NSCursor.closedHand : NSCursor.openHand).set()
                }
            }
            .background(Palette.canvas(scheme == .dark))
            .overlay(alignment: .bottomLeading) {
                if showLegend {
                    LegendView(split: model.splitPrePost && model.showSends, sends: model.showSends,
                               atmos: model.edges.contains(where: \.inactiveRoute),
                               collapsed: model.nodes.contains(where: \.isCollapsed),
                               onClose: { showLegend = false })
                        .onHover { pan.overOverlay = $0 }
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.hasRowOverrides {
                    Button { model.resetRowOverrides() } label: {
                        Label("Reset Block Positions", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Put the blocks you dragged back in their automatic position")
                    .onHover { pan.overOverlay = $0 }
                    .padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showMinimap && model.focusID == nil {
                    MinimapView(nodes: model.nodes, colGap: colGap, nodeH: Layout.nodeHeight(extraLines: model.extraLines),
                                graphSize: currentSize, zoom: z, dark: scheme == .dark, tracker: tracker)
                        .onHover { pan.overOverlay = $0 }
                }
            }
            .background {
                // Esc also leaves focus mode (invisible; no button on screen).
                Button("") { model.focusID = nil }.keyboardShortcut(.cancelAction).opacity(0).disabled(model.focusID == nil)
            }
            .onAppear(perform: installMonitor)
            .onAppear(perform: installPanMonitor)
            .onDisappear {
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
                if let m = panMonitor { NSEvent.removeMonitor(m); panMonitor = nil }
            }
        }
    }

    /// Size of the graph as the model is *now* (closures above captured an older value).
    private var currentSize: CGSize {
        GraphContent(nodes: model.nodes, edges: model.edges,
                     colGap: colGap,
                     showGroupNames: model.showGroupNames, showInserts: model.showInserts, showVCA: model.showVCA).size
    }

    private func fitZoom(_ content: CGSize, in view: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, view.width > 0, view.height > 0 else { return 1 }
        let margin: CGFloat = 0.98
        let fitW = view.width * margin / content.width, fitH = view.height * margin / content.height
        let fitBoth = min(fitW, fitH)
        // Prefer the whole chain on screen, but never so small that blocks become unreadable:
        // below `readable`, fit the width (scroll vertically) and keep at least `minReadable`.
        let readable: CGFloat = 1.0, minReadable: CGFloat = 0.85
        if fitBoth >= readable { return min(2.2, fitBoth) }
        return max(minReadable, min(readable, fitW))
    }

    /// Right-click on a node focuses it; in focus mode a right-click on another block zooms in
    /// on that block's routing, and a right-click on an empty spot (or Esc) leaves focus mode.
    private func installMonitor() {
        guard monitor == nil else { return }
        let model = self.model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            if model.focusID != nil, event.window?.isKeyWindow == true,
               model.hoveredID == nil || model.hoveredID == model.focusID {
                model.focusID = nil
                return nil
            }
            if let id = model.hoveredID {
                model.focusID = id
                model.hoveredID = nil
                return nil
            }
            return event
        }
    }

    /// Panning: drag an empty spot of the canvas, or anywhere with the hand tool, while holding
    /// Space, or with the middle mouse button.
    private func installPanMonitor() {
        guard panMonitor == nil else { return }
        let model = self.model, st = self.pan, hand = $handTool
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                            .otherMouseDown, .otherMouseDragged, .otherMouseUp, .keyDown, .keyUp]
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { ev in
            switch ev.type {
            case .keyDown, .keyUp:
                // Space = temporary hand tool, unless typing (e.g. in the search field).
                guard ev.keyCode == 49, !(ev.window?.firstResponder is NSText) else { return ev }
                st.space = ev.type == .keyDown
                (st.space || hand.wrappedValue ? NSCursor.openHand : NSCursor.arrow).set()
                return nil
            case .leftMouseDown, .otherMouseDown:
                guard let cv = ev.window?.contentView,
                      let hit = cv.hitTest(cv.convert(ev.locationInWindow, from: nil)),
                      !(hit is NSScroller), let sv = hit.enclosingScrollView, sv.documentView != nil else { return ev }
                if st.overOverlay { return ev }
                let force = ev.type == .otherMouseDown || st.space || hand.wrappedValue
                guard force || model.hoveredID == nil else { return ev }
                st.scrollView = sv; st.last = ev.locationInWindow; st.moved = false; st.swallowed = force
                if force { NSCursor.closedHand.set(); return nil }
                return ev // an empty-canvas click still deselects
            case .leftMouseDragged, .otherMouseDragged:
                guard let sv = st.scrollView, let doc = sv.documentView else { return ev }
                let p = ev.locationInWindow
                let dx = p.x - st.last.x, dy = p.y - st.last.y
                st.last = p
                if !st.moved { st.moved = true; NSCursor.closedHand.set() }
                let clip = sv.contentView
                var o = clip.bounds.origin
                o.x -= dx
                o.y += doc.isFlipped ? dy : -dy
                o.x = min(max(0, o.x), max(0, doc.frame.width - clip.bounds.width))
                o.y = min(max(0, o.y), max(0, doc.frame.height - clip.bounds.height))
                clip.scroll(to: o)
                sv.reflectScrolledClipView(clip)
                return nil
            case .leftMouseUp, .otherMouseUp:
                guard st.scrollView != nil else { return ev }
                st.scrollView = nil
                if st.moved { model.lastPanEnd = Date() }
                (st.space || hand.wrappedValue ? NSCursor.openHand : NSCursor.arrow).set()
                return st.swallowed ? nil : ev
            default:
                return ev
            }
        }
    }
}

/// The drawable graph (no scrolling) — also used for PNG snapshots.
struct GraphContent: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    var groups: [ProToolsAX.PTGroup] = []
    var colGap: CGFloat = Layout.colGap
    var showGroupNames = false
    var showInserts = false
    var showVCA = false
    var splitPrePost = false
    var extraLines: Int { [showGroupNames, showInserts, showVCA].filter { $0 }.count }
    var nodeH: CGFloat { Layout.nodeHeight(extraLines: extraLines) }
    static let preBlue = Color(red: 0.16, green: 0.47, blue: 0.98)
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    /// Zoom factor. Everything is laid out and drawn at this size (vector-sharp), not scaled afterwards.
    var scale: CGFloat = 1
    var lit: Set<String>? = nil
    var query: String = ""
    var selectedID: String? = nil
    var onHover: (String, Bool) -> Void = { _, _ in }
    var onTap: (String) -> Void = { _ in }
    var onMove: (String, Double) -> Void = { _, _ in }
    var sendMode: SessionModel.SendMode = .all
    /// Lines of one bus come together in a junction in front of the target, then go in as one.
    var bundle = false
    var showBusNames = false
    var fullColor = false
    var onToggleCollapse: ((String) -> Void)? = nil
    @State private var dragID: String?
    @State private var dragDY: CGFloat = 0

    /// Horizontal distance from a bundle's junction to the target block.
    private var junctionGap: CGFloat { showBusNames ? 112 : 24 }

    var maxCol: Int { nodes.map(\.column).max() ?? 0 }
    var size: CGSize {
        let maxRow = nodes.map(\.row).max() ?? 0
        return CGSize(width: Layout.pad * 2 + CGFloat(maxCol + 1) * (Layout.nodeW + colGap) - colGap,
                      height: Layout.pad * 2 + 26 + CGFloat(maxRow + 1) * (nodeH + Layout.rowGap))
    }

    private func header(_ c: Int) -> String {
        let kinds = Set(nodes.filter { $0.column == c }.map(\.kind))
        if kinds == [.deviceIn] { return "Hardware inputs" }
        if kinds == [.deviceOut] {
            return nodes.contains { $0.column == c && $0.id == "d:renderer" } ? "Atmos renderer & hardware outputs" : "Hardware outputs"
        }
        if kinds == [.endpoint] { return "Output paths" }
        let first = nodes.contains { $0.kind == .deviceIn } ? 1 : 0
        return c == first ? "Sources" : "Buses · level \(c - first)"
    }

    /// One dashed band per group around its members in the source column.
    private var groupBands: [(String, String, CGRect)] {
        guard !groups.isEmpty else { return [] }
        let first = nodes.filter { $0.kind == .track }.map(\.column).min() ?? 0
        var out: [(String, String, CGRect)] = []
        for g in groups {
            let members = nodes.filter { $0.column == first && $0.groupIDs.first == g.id }
            guard let top = members.map(\.row).min(), let bottom = members.map(\.row).max(), let any = members.first else { continue }
            let f = Layout.frame(any, gap: colGap, h: nodeH)
            let y0 = Layout.frame(GraphNode.probe(row: top), gap: colGap, h: nodeH).minY, y1 = Layout.frame(GraphNode.probe(row: bottom), gap: colGap, h: nodeH).maxY
            let label = "\(g.id) · \(g.name)" + (g.vca.map { " (\($0))" } ?? "")
            out.append((g.id, label, CGRect(x: f.minX - 8, y: y0 - 12, width: f.width + 16, height: y1 - y0 + 20)))
        }
        return out
    }

    private func infoLines(_ n: GraphNode) -> [String] {
        guard n.kind == .track else { return Array(repeating: "", count: extraLines) }
        var l: [String] = []
        if showGroupNames { l.append("Group: " + (n.groupNames.isEmpty ? "—" : n.groupNames.joined(separator: ", "))) }
        if showInserts { l.append("Inserts: " + (n.inserts.isEmpty ? "—" : n.inserts.joined(separator: " · "))) }
        if showVCA { l.append("VCA: " + (n.vcaNames.isEmpty ? "—" : n.vcaNames.joined(separator: ", "))) }
        return l
    }

    /// Node frame in on-screen (zoomed) coordinates.
    private func frame(_ n: GraphNode) -> CGRect { scaled(rawFrame(n)) }
    /// Unscaled frame, including the live offset of a block being dragged.
    private func rawFrame(_ n: GraphNode) -> CGRect {
        let f = Layout.frame(n, gap: colGap, h: nodeH)
        return n.id == dragID ? f.offsetBy(dx: 0, dy: dragDY / scale) : f
    }
    private func scaled(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    /// The connections to draw: sends merged when pre/post isn't distinguished, and send lines
    /// left out when they're only wanted for the selected track.
    private var drawEdges: [GraphEdge] {
        var out: [GraphEdge] = []
        if splitPrePost {
            out = edges
        } else {
            var seen: [String: Int] = [:]
            for e in edges {
                guard e.isSend else { out.append(e); continue }
                let key = e.from + ">" + e.to
                if let i = seen[key] {
                    out[i].muted = out[i].muted && e.muted // muted only if all are
                    out[i].count += e.count
                } else {
                    var c = e; c.isPre = false
                    seen[key] = out.count
                    out.append(c)
                }
            }
        }
        guard sendMode == .selection else { return out }
        return out.filter { e in
            guard e.isSend else { return true }
            guard let lit else { return false }
            return lit.contains(e.from) && lit.contains(e.to)
        }
    }

    private struct EdgeStyle {
        var on: Bool
        var color: Color
        var alpha: Double
        var width: CGFloat
        var dash: [CGFloat]
        var pre: Bool
    }

    private func style(_ e: GraphEdge, from a: GraphNode) -> EdgeStyle {
        let on = lit == nil || (lit!.contains(e.from) && lit!.contains(e.to))
        let color = (a.kind == .track ? a.color : Color.gray).readable(dark: dark)
        let alpha = on ? (e.inactiveRoute ? 0.28 : e.muted ? 0.3 : (e.isSend ? 0.75 : 0.95)) : 0.07
        // A collapsed block's line stands for several tracks: a little thicker.
        let extra = e.count > 1 ? min(2, log2(CGFloat(e.count)) * 0.5) : 0
        let w: CGFloat = (on && lit != nil ? 2.5 : 1.6) + extra
        let pre = splitPrePost && e.isSend && e.isPre
        let dash: [CGFloat] = e.inactiveRoute ? [2, 5] : (!e.isSend ? [] : (pre ? [6, 6] : [7, 4]))
        return EdgeStyle(on: on, color: color, alpha: alpha, width: e.inactiveRoute ? 1.1 : w, dash: dash, pre: pre)
    }

    private func curve(_ p0: CGPoint, _ p1: CGPoint) -> Path {
        var path = Path()
        path.move(to: p0)
        if p1.x > p0.x {
            let dx = max(40, (p1.x - p0.x) * 0.5)
            path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
        } else { // feedback loop: route around
            let dx: CGFloat = 60
            path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y + 40), control2: CGPoint(x: p1.x - dx, y: p1.y + 40))
        }
        return path
    }

    private func arrowHead(_ ctx: GraphicsContext, at p: CGPoint, color: Color) {
        var head = Path()
        head.move(to: p)
        head.addLine(to: CGPoint(x: p.x - 7, y: p.y - 4))
        head.addLine(to: CGPoint(x: p.x - 7, y: p.y + 4))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    private func strokeEdge(_ ctx: GraphicsContext, _ path: Path, _ s: EdgeStyle, muted: Bool) {
        ctx.stroke(path, with: .color(s.color.opacity(s.alpha)),
                   style: StrokeStyle(lineWidth: s.width, lineCap: .butt, dash: s.dash))
        if s.pre {
            // Pro Tools marks pre-fader sends in blue: blue dots in the gaps of the dashes.
            ctx.stroke(path, with: .color(Self.preBlue.opacity(s.on ? (muted ? 0.45 : 1) : 0.07)),
                       style: StrokeStyle(lineWidth: s.width + 1.6, lineCap: .round, dash: [0.01, 12], dashPhase: -9))
        }
    }

    private func preTag(_ ctx: GraphicsContext, at p0: CGPoint, muted: Bool) {
        // Small "PRE" tag right after the source block (one per line, no overlap).
        let tag = ctx.resolve(Text("PRE").font(.system(size: 6.5, weight: .heavy)).foregroundColor(.white))
        let ts = tag.measure(in: CGSize(width: 40, height: 12))
        let r = CGRect(x: p0.x + 5, y: p0.y - ts.height / 2 - 0.5, width: ts.width + 4, height: ts.height + 1)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Self.preBlue.opacity(muted ? 0.55 : 1)))
        ctx.draw(tag, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
    }

    private func drawLines(_ ctx: GraphicsContext, byID: [String: GraphNode]) {
        let drawEdges = self.drawEdges
        func rank(_ e: GraphEdge) -> Int { !e.isSend ? 0 : (e.isPre ? 2 : 1) }
        // Every outgoing connection of a block gets its own start point, ordered by where it
        // goes, so a line (and its PRE tag) is unambiguous at the source.
        var outgoing: [String: [GraphEdge]] = [:]
        for e in drawEdges where byID[e.to] != nil { outgoing[e.from, default: []].append(e) }
        for key in outgoing.keys {
            outgoing[key]!.sort { x, y in
                let ry = byID[x.to]!.row, sy = byID[y.to]!.row
                return ry == sy ? (rank(x), x.label) < (rank(y), y.label) : ry < sy
            }
        }
        func start(_ e: GraphEdge, _ fa: CGRect) -> CGPoint {
            let outs = outgoing[e.from] ?? [e]
            let oi = outs.firstIndex(of: e) ?? 0
            let ospacing = outs.count > 1 ? min(8, (nodeH - 8) / CGFloat(outs.count - 1)) : 0
            return CGPoint(x: fa.maxX, y: fa.midY + (CGFloat(oi) - CGFloat(outs.count - 1) / 2) * ospacing)
        }

        if bundle {
            drawBundled(ctx, drawEdges, byID: byID, start: start)
            return
        }

        // Several connections between the same two blocks (e.g. output + post send + pre send)
        // get their own parallel lane instead of sharing one line.
        var lanes: [String: [GraphEdge]] = [:]
        for e in drawEdges { lanes[e.from + ">" + e.to, default: []].append(e) }
        for key in lanes.keys { lanes[key]!.sort { (rank($0), $0.label) < (rank($1), $1.label) } }
        for e in drawEdges {
            guard let a = byID[e.from], let b = byID[e.to] else { continue }
            let fa = rawFrame(a), fb = rawFrame(b)
            let group = lanes[e.from + ">" + e.to] ?? [e]
            let n = group.count
            let i = group.firstIndex(of: e) ?? 0
            let spacing = n > 1 ? min(10, (nodeH - 8) / CGFloat(n - 1)) : 0
            let off = (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
            let p0 = start(e, fa)
            let p1 = CGPoint(x: fb.minX, y: fb.midY + off)
            let s = style(e, from: a)
            strokeEdge(ctx, curve(p0, p1), s, muted: e.muted)
            arrowHead(ctx, at: p1, color: s.color.opacity(s.on ? 0.95 : 0.07))
            if s.pre && s.on { preTag(ctx, at: p0, muted: e.muted) }
        }
    }

    /// Bundled drawing: per target, every bus coming in gets one port. All lines on that bus meet
    /// in a junction in front of the target and continue as one trunk (with the bus name on it).
    private func drawBundled(_ ctx: GraphicsContext, _ drawEdges: [GraphEdge], byID: [String: GraphNode],
                             start: (GraphEdge, CGRect) -> CGPoint) {
        func portKey(_ e: GraphEdge) -> String { e.to + "|" + SessionModel.norm(SessionModel.busPath(e)) }
        var ports: [String: [String]] = [:]       // target → its port keys
        var members: [String: [GraphEdge]] = [:]  // port key → edges
        var rowsIn: [String: [Double]] = [:]
        for e in drawEdges {
            guard let a = byID[e.from], byID[e.to] != nil else { continue }
            let pk = portKey(e)
            if members[pk] == nil { ports[e.to, default: []].append(pk) }
            members[pk, default: []].append(e)
            rowsIn[pk, default: []].append(a.row)
        }
        // Ports in the order their sources sit, to keep lines from crossing.
        func avg(_ v: [Double]?) -> Double { guard let v, !v.isEmpty else { return 0 }; return v.reduce(0, +) / Double(v.count) }
        for t in ports.keys { ports[t]!.sort { avg(rowsIn[$0]) < avg(rowsIn[$1]) } }

        var junction: [String: CGPoint] = [:], port: [String: CGPoint] = [:]
        for (t, keys) in ports {
            guard let b = byID[t] else { continue }
            let fb = rawFrame(b)
            let n = CGFloat(keys.count)
            let pSp = keys.count > 1 ? min(8, (nodeH - 8) / (n - 1)) : 0
            let jSp: CGFloat = showBusNames ? 16 : max(pSp, 7)
            for (i, pk) in keys.enumerated() {
                let o = CGFloat(i) - (n - 1) / 2
                port[pk] = CGPoint(x: fb.minX, y: fb.midY + o * pSp)
                junction[pk] = CGPoint(x: fb.minX - junctionGap, y: fb.midY + o * jSp)
            }
        }

        // 1. Lines that would run close together are combined automatically: neighbouring blocks
        //    in a column that go to the same place share a bus bar. Their lines run into the bar
        //    and leave it as one line per destination.
        let bars = combineBars(drawEdges, byID: byID, hasJunction: { junction[portKey($0)] != nil }, portKey: portKey)
        var barOf: [String: Int] = [:]
        for (i, bar) in bars.enumerated() { for id in bar.ids { barOf[id] = i } }
        drawBars(ctx, bars, drawEdges, byID: byID, junction: junction, portKey: portKey)

        // 2. Every other connection (and, while a track is selected, its own lines): source → junction.
        for e in drawEdges {
            guard let a = byID[e.from], let j = junction[portKey(e)] else { continue }
            let s = style(e, from: a)
            if barOf[e.from] != nil { continue } // drawn as part of its bar (also while lit)
            let p0 = start(e, rawFrame(a))
            strokeEdge(ctx, curve(p0, j), s, muted: e.muted)
            if s.pre && s.on { preTag(ctx, at: p0, muted: e.muted) }
        }

        // 3. Per bus: junction → target, plus the bus name.
        for (pk, es) in members {
            guard let j = junction[pk], let p = port[pk], let target = byID[es[0].to] else { continue }
            let styles = es.compactMap { e in byID[e.from].map { style(e, from: $0) } }
            let on = styles.contains(where: \.on)
            let sameSource = Set(es.map(\.from)).count == 1
            let color = sameSource ? styles[0].color : Color.secondary
            let allSends = es.allSatisfy(\.isSend)
            let width: CGFloat = (on && lit != nil ? 2.5 : 1.8)
            var trunk = Path()
            trunk.move(to: j)
            let straight = showBusNames ? junctionGap * 0.62 : 0
            trunk.addLine(to: CGPoint(x: j.x + straight, y: j.y))
            let rest = p.x - (j.x + straight)
            trunk.addCurve(to: p, control1: CGPoint(x: j.x + straight + rest * 0.5, y: j.y),
                           control2: CGPoint(x: p.x - rest * 0.5, y: p.y))
            ctx.stroke(trunk, with: .color(color.opacity(on ? 0.9 : 0.07)),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: allSends ? [7, 4] : []))
            arrowHead(ctx, at: p, color: color.opacity(on ? 0.95 : 0.07))
            let total = es.reduce(0) { $0 + $1.count }
            if es.count > 1 || total > 1 {
                let r: CGFloat = 2.6
                ctx.fill(Path(ellipseIn: CGRect(x: j.x - r, y: j.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color.opacity(on ? 0.95 : 0.07)))
            }
            guard showBusNames, on else { continue }
            let bus = SessionModel.busPath(es[0])
            // The name is redundant when the target block is called the same (or is the path itself).
            let redundant = target.kind == .endpoint || SessionModel.normName(bus) == SessionModel.normName(target.name)
            var label = redundant ? "" : bus
            if total > 1 { label += label.isEmpty ? "×\(total)" : "  ×\(total)" }
            guard !label.isEmpty else { continue }
            let maxW = junctionGap - 20
            var text = ctx.resolve(Text(label).font(.system(size: 8.5, weight: .medium)).foregroundColor(.secondary))
            var ts = text.measure(in: CGSize(width: 1000, height: 20))
            var shown = label
            while ts.width > maxW && shown.count > 3 {
                shown = String(shown.dropLast(2)) ; let t = shown + "…"
                text = ctx.resolve(Text(t).font(.system(size: 8.5, weight: .medium)).foregroundColor(.secondary))
                ts = text.measure(in: CGSize(width: 1000, height: 20))
            }
            let rect = CGRect(x: j.x + 5, y: j.y - ts.height / 2 - 1, width: ts.width + 8, height: ts.height + 2)
            let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            ctx.fill(pill, with: .color(Palette.canvas(dark)))
            ctx.stroke(pill, with: .color(color.opacity(0.55)), lineWidth: 0.8)
            ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    private struct Bar { var ids: [String]; var x: CGFloat; var top: CGFloat; var bottom: CGFloat }

    /// A lone block: one horizontal line with the slot names next to each other (A, B, …, Out).
    /// Sends branch off downwards like a staircase (the leftmost deepest, so nothing crosses);
    /// Out is always last and continues the line itself. Several outputs all leave the one Out dot.
    private func drawSingle(_ ctx: GraphicsContext, id: String, x0: CGFloat,
                            _ rails: [(label: String, isSend: Bool, edges: [GraphEdge], j: CGPoint)],
                            byID: [String: GraphNode], isOn: (GraphEdge) -> Bool) {
        guard let n = byID[id] else { return }
        let f = rawFrame(n), y = f.midY
        let highlight = lit != nil
        let color = n.color.readable(dark: dark)
        let sends = rails.filter(\.isSend).sorted { ($0.label, $0.j.y) < ($1.label, $1.j.y) }
        let outs = rails.filter { !$0.isSend }
        // One slot per send letter (a letter going to two places still has one name).
        var letters: [String] = []
        for s in sends where !letters.contains(s.label) { letters.append(s.label) }
        let sp: CGFloat = 13
        func slotX(_ i: Int) -> CGFloat { x0 + 2 + CGFloat(i) * sp }
        let outX = slotX(letters.count) + (outs.isEmpty ? 0 : 4)
        let endX = outs.isEmpty ? slotX(max(0, letters.count - 1)) : outX
        let anyOn = rails.contains { $0.edges.contains(where: isOn) }
        func alpha(_ on: Bool, _ normal: Double) -> Double { on ? (highlight ? 1 : normal) : 0.07 }
        let wBoost: CGFloat = highlight ? 0.8 : 0

        var line = Path()
        line.move(to: CGPoint(x: f.maxX, y: y))
        line.addLine(to: CGPoint(x: endX, y: y))
        ctx.stroke(line, with: .color(color.opacity(alpha(anyOn, 0.9))), lineWidth: 1.6 + (anyOn ? wBoost : 0))

        func label(_ t: String, at x: CGFloat, on: Bool) {
            let r = ctx.resolve(Text(t).font(.system(size: 7, weight: .bold)).foregroundColor(.secondary))
            var lc = ctx; lc.opacity = highlight && !on ? 0.3 : 1
            lc.draw(r, at: CGPoint(x: x, y: y - 7), anchor: .center)
        }
        func dot(_ x: CGFloat, _ yy: CGFloat, on: Bool, r: CGFloat = 2.5) {
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: yy - r, width: 2 * r, height: 2 * r)), with: .color(color.opacity(alpha(on, 0.95))))
        }
        func trunk(from p: CGPoint, to j: CGPoint, send: Bool, edges: [GraphEdge], on: Bool) {
            var t = Path()
            t.move(to: p)
            t.addLine(to: CGPoint(x: endX + 8, y: p.y))
            t.addPath(curve(CGPoint(x: endX + 8, y: p.y), j))
            let muted = edges.allSatisfy(\.muted)
            let a = on ? (muted ? 0.3 : (highlight ? 1 : (send ? 0.75 : 0.95))) : 0.07
            ctx.stroke(t, with: .color(color.opacity(a)),
                       style: StrokeStyle(lineWidth: 1.6 + (on ? wBoost : 0), lineCap: .butt, dash: send ? [7, 4] : []))
            if splitPrePost && edges.allSatisfy({ $0.isSend && $0.isPre }) {
                ctx.stroke(t, with: .color(Self.preBlue.opacity(on ? 1 : 0.07)),
                           style: StrokeStyle(lineWidth: 3.2, lineCap: .round, dash: [0.01, 12], dashPhase: -9))
            }
        }

        // Sends: drop down from their slot, the leftmost deepest, then run right underneath.
        let m = letters.count
        let step = m > 0 ? min(7, 24 / CGFloat(m)) : 0
        for (li, letter) in letters.enumerated() {
            let x = slotX(li)
            let group = sends.filter { $0.label == letter }
            let on = group.contains { $0.edges.contains(where: isOn) }
            let drop = y + CGFloat(m - li) * step
            var v = Path()
            v.move(to: CGPoint(x: x, y: y))
            v.addLine(to: CGPoint(x: x, y: drop))
            ctx.stroke(v, with: .color(color.opacity(alpha(on, 0.9))), style: StrokeStyle(lineWidth: 1.6, dash: [3, 2]))
            for s in group {
                trunk(from: CGPoint(x: x, y: drop), to: s.j, send: true, edges: s.edges, on: s.edges.contains(where: isOn))
            }
            // The send's dot hangs under the line (the output's dot sits on it).
            dot(x, drop, on: on, r: 2.3)
            label(letter, at: x, on: on)
        }
        // Out: the end of the line; every output leaves this one dot.
        if !outs.isEmpty {
            let on = outs.contains { $0.edges.contains(where: isOn) }
            for o in outs {
                trunk(from: CGPoint(x: outX, y: y), to: o.j, send: false, edges: o.edges, on: o.edges.contains(where: isOn))
            }
            dot(outX, y, on: on, r: 2.8)
            label("Out", at: outX, on: on)
        }
    }

    /// Finds runs of neighbouring blocks (same column, at most ~1 row apart) with the same
    /// main output that together send enough lines to clutter the view.
    private func combineBars(_ edges: [GraphEdge], byID: [String: GraphNode], hasJunction: (GraphEdge) -> Bool,
                             portKey: (GraphEdge) -> String) -> [Bar] {
        var targets: [String: Set<String>] = [:], mains: [String: Set<String>] = [:]
        for e in edges where hasJunction(e) && byID[e.from] != nil {
            targets[e.from, default: []].insert(portKey(e))
            if !e.isSend { mains[e.from, default: []].insert(e.to) }
        }
        let sources = targets.keys.compactMap { byID[$0] }
        var bars: [Bar] = []
        for col in Set(sources.map(\.column)) {
            let colNodes = sources.filter { $0.column == col }.sorted { $0.row < $1.row }
            var run: [GraphNode] = []
            func flush() {
                defer { run = [] }
                let lines = run.reduce(0) { $0 + (targets[$1.id]?.count ?? 0) }
                guard !run.isEmpty, lines > 0 else { return } // a single block gets its own small rails too
                let frames = run.map(rawFrame)
                bars.append(Bar(ids: run.map(\.id), x: frames[0].maxX + 14,
                                top: frames.map(\.midY).min()!, bottom: frames.map(\.midY).max()!))
            }
            for n in colNodes {
                if let first = run.first, let last = run.last {
                    // Bus columns are sparser than the source column: allow a bit more room.
                    let close = n.row - last.row <= (col == 0 ? 1.7 : 3.2)
                    let m = mains[n.id] ?? [], m0 = mains[first.id] ?? []
                    let related = m.isEmpty && m0.isEmpty ? !(targets[n.id] ?? []).isDisjoint(with: targets[first.id] ?? []) : m == m0
                    if !(close && related) { flush() }
                }
                run.append(n)
            }
            flush()
        }
        return bars
    }

    /// Draws combined lines as a small schematic: per destination one vertical rail, in a fixed
    /// order from left to right — outputs first, then send A, B, C… Each block's line runs to
    /// the right with a dot on every rail it feeds (a crossing without a dot is no connection).
    /// Every rail leaves once, in the order of where it goes, so the lines don't cross.
    private func drawBars(_ ctx: GraphicsContext, _ bars: [Bar], _ edges: [GraphEdge], byID: [String: GraphNode],
                          junction: [String: CGPoint], portKey: (GraphEdge) -> String) {
        func isOn(_ e: GraphEdge) -> Bool { lit == nil || (lit!.contains(e.from) && lit!.contains(e.to)) }
        let highlight = lit != nil
        func slot(_ e: GraphEdge) -> String {
            guard e.isSend, let r = e.label.range(of: ": ") else { return "" }
            return String(e.label[..<r.lowerBound])
        }
        struct Rail { var key: String; var label: String; var isSend: Bool; var edges: [GraphEdge]; var j: CGPoint }
        for bar in bars {
            let ids = Set(bar.ids)
            let es = edges.filter { ids.contains($0.from) && junction[portKey($0)] != nil }
            var railsByKey: [String: Rail] = [:]
            for e in es {
                let key = (e.isSend ? "s" + slot(e) : "o") + "|" + portKey(e)
                if railsByKey[key] == nil {
                    railsByKey[key] = Rail(key: key, label: e.isSend ? slot(e) : "Out", isSend: e.isSend, edges: [], j: junction[portKey(e)]!)
                }
                railsByKey[key]!.edges.append(e)
            }
            // Fixed lane order: sends by slot (A, B, C…), the output last; within that, by where they go.
            let rails = railsByKey.values.sorted {
                ($0.isSend ? 0 : 1, $0.label, $0.j.y) < ($1.isSend ? 0 : 1, $1.label, $1.j.y)
            }
            guard !rails.isEmpty else { continue }
            if bar.ids.count == 1 {
                drawSingle(ctx, id: bar.ids[0], x0: bar.x, rails.map { ($0.label, $0.isSend, $0.edges, $0.j) }, byID: byID, isOn: isOn)
                continue
            }
            let room = max(20, colGap - junctionGap - 70)
            let spacing = min(14, room / CGFloat(max(1, rails.count)))
            let railX = rails.indices.map { bar.x + 2 + CGFloat($0) * spacing }
            let lastX = railX.last!
            let colors = bar.ids.compactMap { byID[$0]?.color.readable(dark: dark) }
            let sameColor = Set(colors.map(\.description)).count == 1
            let railColor = sameColor ? colors[0] : Color.secondary
            // While a block is hovered or selected, the bar keeps its shape: only the parts its
            // signal runs through light up, the rest fades.
            let dim = 0.07
            func a(_ on: Bool, _ normal: Double = 0.9) -> Double { on ? (highlight ? 1 : normal) : dim }
            let wBoost: CGFloat = highlight ? 0.8 : 0

            // Block lines: as far as the last rail they feed, with a dot on each of their rails.
            var midYs: [String: CGFloat] = [:]
            for id in bar.ids { if let n = byID[id] { midYs[id] = rawFrame(n).midY } }
            func draw(_ id: String, lit wantOn: Bool) {
                guard let n = byID[id], let y = midYs[id] else { return }
                let used = rails.indices.filter { i in rails[i].edges.contains { $0.from == id } }
                let onUsed = used.filter { i in rails[i].edges.contains { $0.from == id && isOn($0) } }
                guard (wantOn ? onUsed.max() : used.max()) != nil else { return }
                let c = n.color.readable(dark: dark)
                if wantOn {
                    var line = Path()
                    line.move(to: CGPoint(x: rawFrame(n).maxX, y: y))
                    line.addLine(to: CGPoint(x: railX[onUsed.max()!], y: y))
                    ctx.stroke(line, with: .color(c.opacity(a(true))), lineWidth: 1.4 + wBoost)
                    for i in onUsed {
                        ctx.fill(Path(ellipseIn: CGRect(x: railX[i] - 2.8, y: y - 2.8, width: 5.6, height: 5.6)), with: .color(c.opacity(a(true))))
                    }
                } else {
                    let on = !highlight && !onUsed.isEmpty
                    var line = Path()
                    line.move(to: CGPoint(x: rawFrame(n).maxX, y: y))
                    line.addLine(to: CGPoint(x: railX[used.max()!], y: y))
                    ctx.stroke(line, with: .color(c.opacity(a(on))), lineWidth: 1.4)
                    for i in used {
                        ctx.fill(Path(ellipseIn: CGRect(x: railX[i] - 2.3, y: y - 2.3, width: 4.6, height: 4.6)), with: .color(c.opacity(a(on))))
                    }
                }
            }
            for id in bar.ids { draw(id, lit: false) }

            // Exits: ordered by where they go, spread around the middle of the group.
            let order = rails.indices.sorted { rails[$0].j.y < rails[$1].j.y }
            let groupMid = (bar.top + bar.bottom) / 2
            let n = CGFloat(rails.count)
            for (rank, i) in order.enumerated() {
                let r = rails[i]
                let ys = r.edges.compactMap { midYs[$0.from] }
                let top = ys.min()!, bottom = ys.max()!
                // A rail is stretched when its exit falls outside it (e.g. a single block with several rails).
                let exitY = groupMid + (CGFloat(rank) - (n - 1) / 2) * 9
                let onYs = r.edges.filter(isOn).compactMap { midYs[$0.from] }
                let railOn = !onYs.isEmpty
                let dash: [CGFloat] = r.isSend ? [4, 3] : []
                var rail = Path()
                rail.move(to: CGPoint(x: railX[i], y: min(top, exitY)))
                rail.addLine(to: CGPoint(x: railX[i], y: max(bottom, exitY)))
                ctx.stroke(rail, with: .color(railColor.opacity(highlight ? dim : 0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: dash))
                if highlight && railOn {
                    // Only the stretch of the rail between the lit blocks and the exit.
                    var part = Path()
                    part.move(to: CGPoint(x: railX[i], y: min(onYs.min()!, exitY)))
                    part.addLine(to: CGPoint(x: railX[i], y: max(onYs.max()!, exitY)))
                    ctx.stroke(part, with: .color(railColor.opacity(1)), style: StrokeStyle(lineWidth: 2.2 + wBoost, lineCap: .round, dash: dash))
                }
                if spacing >= 11 {
                    let t = ctx.resolve(Text(r.label).font(.system(size: 7, weight: .bold)).foregroundColor(.secondary))
                    var lc = ctx; lc.opacity = highlight && !railOn ? 0.3 : 1
                    lc.draw(t, at: CGPoint(x: railX[i], y: min(top, exitY) - 7), anchor: .center)
                }
                // Leave the rail horizontally past the other rails, then curve to the destination.
                let total = r.edges.reduce(0) { $0 + $1.count }
                let w = 1.6 + min(2.2, log2(CGFloat(max(1, total))) * 0.5) + (railOn ? wBoost : 0)
                let allMuted = r.edges.allSatisfy(\.muted)
                var trunk = Path()
                trunk.move(to: CGPoint(x: railX[i], y: exitY))
                trunk.addLine(to: CGPoint(x: lastX + 8, y: exitY))
                trunk.addPath(curve(CGPoint(x: lastX + 8, y: exitY), r.j))
                let tAlpha = railOn ? (allMuted ? 0.3 : (highlight ? 1 : (r.isSend ? 0.75 : 0.95))) : dim
                ctx.stroke(trunk, with: .color(railColor.opacity(tAlpha)),
                           style: StrokeStyle(lineWidth: w, lineCap: .butt, dash: r.isSend ? [7, 4] : []))
                if splitPrePost && r.edges.allSatisfy({ $0.isSend && $0.isPre }) {
                    ctx.stroke(trunk, with: .color(Self.preBlue.opacity(railOn ? 1 : dim)),
                               style: StrokeStyle(lineWidth: w + 1.6, lineCap: .round, dash: [0.01, 12], dashPhase: -9))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: railX[i] - 2.6, y: exitY - 2.6, width: 5.2, height: 5.2)),
                         with: .color(railColor.opacity(a(railOn))))
            }
            // Lit block lines on top, so they stay readable over the faded rails.
            if highlight { for id in bar.ids { draw(id, lit: true) } }
        }
    }

    var body: some View {
        let k = scale
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let size = self.size
        let sendCounts = Dictionary(edges.filter(\.isSend).map { ($0.from, $0.count) }, uniquingKeysWith: +)
        ZStack(alignment: .topLeading) {
            ForEach(0...maxCol, id: \.self) { c in
                Text(header(c))
                    .font(.system(size: 10 * k, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .fixedSize()
                    .offset(x: (Layout.pad + CGFloat(c) * (Layout.nodeW + colGap)) * k, y: (Layout.pad - 10) * k)
            }
            ForEach(groupBands, id: \.0) { band in
                let (gid, label, raw) = band
                let rect = scaled(raw)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9 * k).fill(Color.accentColor.opacity(0.07))
                    RoundedRectangle(cornerRadius: 9 * k).strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: max(1, k), dash: [4 * k, 3 * k]))
                    Text(label).font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .fixedSize()
                        .padding(.horizontal, 6 * k).padding(.vertical, 1 * k)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 10 * k, y: -8 * k)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .id(gid)
            }
            Canvas { ctx, _ in
                ctx.scaleBy(x: k, y: k) // vector drawing at the zoomed resolution
                drawLines(ctx, byID: byID)
            }
            .frame(width: size.width * k, height: size.height * k)
            .allowsHitTesting(false)

            ForEach(nodes) { n in
                let f = frame(n)
                let match = !q.isEmpty && (n.name.lowercased().contains(q)
                    || (n.input ?? "").lowercased().contains(q)
                    || n.outputs.contains { $0.lowercased().contains(q) }
                    || n.memberNames.contains { $0.lowercased().contains(q) })
                NodeView(node: n, selected: selectedID == n.id, highlighted: match,
                         dimmed: (lit.map { !$0.contains(n.id) } ?? false) || (!q.isEmpty && !match), scale: k,
                         info: infoLines(n), fullColor: fullColor,
                         hiddenSends: sendMode == .selection ? (sendCounts[n.id] ?? 0) : 0,
                         onToggleCollapse: n.collapseKey.flatMap { key in onToggleCollapse.map { cb in { cb(key) } } })
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .onHover { onHover(n.id, $0) }
                    .onTapGesture { onTap(n.id) }
                    // Drag a block up or down within its column to reveal lines hidden behind others.
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { v in dragID = n.id; dragDY = v.translation.height }
                        .onEnded { v in
                            onMove(n.id, Double(v.translation.height / ((nodeH + Layout.rowGap) * scale)))
                            dragID = nil; dragDY = 0
                        })
                    .zIndex(n.id == dragID ? 1 : 0)
            }
        }
        .frame(width: size.width * k, height: size.height * k, alignment: .topLeading)
    }
}

// MARK: - Minimap

/// Follows the graph's NSScrollView so the minimap can show (and move) the visible area.
final class ScrollTracker: ObservableObject {
    private(set) weak var scrollView: NSScrollView?
    /// Visible part of the (zoomed) graph, top-left origin.
    @Published private(set) var visible: CGRect = .zero
    private var observers: [NSObjectProtocol] = []

    func attach(_ sv: NSScrollView) {
        guard sv !== scrollView else { return }
        scrollView = sv
        observers.forEach(NotificationCenter.default.removeObserver)
        sv.contentView.postsBoundsChangedNotifications = true
        sv.contentView.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            nc.addObserver(forName: name, object: sv.contentView, queue: .main) { [weak self] _ in self?.update() }
        }
        update()
    }

    func update() {
        guard let sv = scrollView else { return }
        var r = sv.contentView.bounds
        if let doc = sv.documentView, !doc.isFlipped { r.origin.y = doc.frame.height - r.maxY }
        if r != visible { visible = r }
    }

    /// Scrolls so that `p` (zoomed graph coordinates) is in the middle of the window.
    func center(on p: CGPoint) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        var o = CGPoint(x: p.x - clip.bounds.width / 2, y: p.y - clip.bounds.height / 2)
        o.x = min(max(0, o.x), max(0, doc.frame.width - clip.bounds.width))
        o.y = min(max(0, o.y), max(0, doc.frame.height - clip.bounds.height))
        if !doc.isFlipped { o.y = doc.frame.height - clip.bounds.height - o.y }
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
    }
}

/// Invisible view inside the scroll view that hands its NSScrollView to the tracker.
struct ScrollFinder: NSViewRepresentable {
    let tracker: ScrollTracker
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let sv = v.enclosingScrollView { tracker.attach(sv); tracker.update() } }
    }
}

/// Overview of the whole graph with the visible area; click or drag in it to jump there.
struct MinimapView: View {
    let nodes: [GraphNode]
    let colGap: CGFloat
    let nodeH: CGFloat
    /// Unzoomed graph size.
    let graphSize: CGSize
    let zoom: CGFloat
    let dark: Bool
    @ObservedObject var tracker: ScrollTracker
    /// Where in the blue frame it was grabbed (relative to its centre), while dragging.
    @State private var grab: CGPoint?

    var body: some View {
        let v = tracker.visible
        // Only useful when the graph doesn't fit in the window.
        let fits = v.width >= graphSize.width * zoom - 1 && v.height >= graphSize.height * zoom - 1
        if !fits && graphSize.width > 0 && graphSize.height > 0 {
            // Fixed width; height follows the graph but stays within bounds, so very tall
            // sessions (hundreds of tracks) remain usable instead of becoming a thin strip.
            let w: CGFloat = 180
            let h = min(280, max(70, w * graphSize.height / graphSize.width))
            let sx = w / graphSize.width, sy = h / graphSize.height
            Canvas { ctx, _ in
                for n in nodes {
                    let f = Layout.frame(n, gap: colGap, h: nodeH)
                    let r = CGRect(x: f.minX * sx, y: f.minY * sy, width: max(2, f.width * sx), height: max(1, f.height * sy))
                    ctx.fill(Path(r), with: .color((n.kind == .track ? n.color.readable(dark: dark) : Color.secondary).opacity(0.85)))
                }
                let vr = CGRect(x: v.minX / zoom * sx, y: v.minY / zoom * sy, width: v.width / zoom * sx, height: v.height / zoom * sy)
                    .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.fill(Path(vr), with: .color(Color.accentColor.opacity(0.15)))
                ctx.stroke(Path(vr), with: .color(Color.accentColor), lineWidth: 1.5)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            // Drag the blue frame to move through the graph; clicking outside it jumps there.
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if grab == nil {
                        let vr = CGRect(x: v.minX / zoom * sx, y: v.minY / zoom * sy, width: v.width / zoom * sx, height: v.height / zoom * sy)
                        grab = vr.contains(g.startLocation) ? CGPoint(x: g.startLocation.x - vr.midX, y: g.startLocation.y - vr.midY) : .zero
                    }
                    let c = CGPoint(x: g.location.x - grab!.x, y: g.location.y - grab!.y)
                    tracker.center(on: CGPoint(x: c.x / sx * zoom, y: c.y / sy * zoom))
                }
                .onEnded { _ in grab = nil })
            .onContinuousHover { p in
                if case .active = p { (grab != nil ? NSCursor.closedHand : NSCursor.openHand).set() }
            }
            .help("Minimap: drag the blue frame to move through the graph, or click to jump")
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }
}

struct NodeView: View {
    let node: GraphNode
    let selected: Bool
    let highlighted: Bool
    let dimmed: Bool
    var scale: CGFloat = 1
    var info: [String] = []
    var fullColor = false
    /// Number of sends whose lines are currently not drawn (send lines only for the selection).
    var hiddenSends = 0
    var onToggleCollapse: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = scale
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 6 * k)
        let filled = fullColor && node.kind == .track
        let trackColor = node.color.readable(dark: dark)
        let fg: Color = filled ? trackColor.contrastText : .primary
        let fg2: Color = filled ? trackColor.contrastText.opacity(0.75) : .secondary
        let fill: Color = node.kind == .track ? (filled ? trackColor : Palette.block(dark))
            : node.kind == .endpoint ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.14)
        let border: Color = selected ? Color.accentColor : (highlighted ? .orange : Color.secondary.opacity(0.35))

        HStack(spacing: 7 * k) {
            switch node.kind {
            case .track:
                if !filled { RoundedRectangle(cornerRadius: 2 * k).fill(trackColor).frame(width: 5 * k).padding(.vertical, 5 * k) }
            case .endpoint: Image(systemName: "arrow.right.circle").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            case .deviceOut: Image(systemName: "hifispeaker.fill").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            case .deviceIn: Image(systemName: "mic.fill").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).font(.system(size: 12 * k, weight: .semibold)).foregroundColor(fg)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 9.5 * k)).foregroundColor(fg2).lineLimit(1)
                ForEach(Array(info.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 9 * k)).foregroundColor(fg2).lineLimit(1).truncationMode(.tail)
                        .frame(height: Layout.infoLineH * k, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            if node.objectPath != nil, let on = node.objectActive {
                Text(on ? "OBJ" : "BED").font(.system(size: 8 * k, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 4 * k).frame(height: 14 * k)
                    .background(RoundedRectangle(cornerRadius: 3 * k).fill(on ? Color.orange : Color.teal))
                    .help(on ? "Signal goes to Atmos object \(node.objectPath!)" : "Signal goes to the bed/bus output")
            }
            if node.muted { badge("M", .yellow) }
            if node.soloed { badge("S", .green) }
            if let toggle = onToggleCollapse {
                Button(action: toggle) {
                    Image(systemName: node.isCollapsed ? "plus.circle.fill" : "minus.circle")
                        .font(.system(size: 12 * k))
                        .foregroundColor(fg2)
                }
                .buttonStyle(.plain)
                .help(node.isCollapsed ? "Expand into \(node.memberNames.count) tracks" : "Collapse into one block again")
            }
        }
        .padding(.horizontal, 7 * k)
        .background {
            ZStack {
                if node.isCollapsed {
                    // Stacked cards: this block stands for several tracks.
                    ForEach([2, 1], id: \.self) { i in
                        shape.fill(fill).overlay(shape.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.8 * max(1, k)))
                            .offset(x: CGFloat(i) * 3 * k, y: CGFloat(-i) * 3 * k)
                    }
                }
                shape.fill(fill)
            }
        }
        .overlay(shape.strokeBorder(border, lineWidth: (selected || highlighted ? 2 : 0.8) * max(1, k)))
        .opacity(dimmed ? 0.25 : (node.inactive ? 0.55 : 1))
        .shadow(color: .black.opacity(0.12), radius: 1.5 * k, y: 1 * k)
        .help(tooltip)
    }

    private var subtitle: String {
        if node.kind == .endpoint { return node.typeLabel == "Output" ? "Output path" : node.typeLabel }
        if node.kind == .deviceIn || node.kind == .deviceOut { return node.detail }
        var s = node.typeLabel
        if let i = node.input, !i.isEmpty { s += "  ·  in: \(i)" }
        if hiddenSends > 0 { s += "  ·  \(hiddenSends) send\(hiddenSends == 1 ? "" : "s")" }
        return s
    }

    private var tooltip: String {
        var s = node.name
        if node.isCollapsed {
            s += "\n\(node.memberNames.count) tracks with the same routing:"
            for m in node.memberNames.prefix(40) { s += "\n  \(m)" }
            if node.memberNames.count > 40 { s += "\n  … and \(node.memberNames.count - 40) more" }
            s += "\nClick ⊕ to expand."
            return s
        }
        if node.kind == .track {
            s += "\nType: \(node.typeLabel)"
            s += "\nInput: \(node.input ?? "—")"
            s += "\nOutput: \(node.outputs.isEmpty ? "—" : node.outputs.joined(separator: ", "))"
            if !node.groupNames.isEmpty { s += "\nGroups: \(node.groupNames.joined(separator: ", "))" }
            if !node.vcaNames.isEmpty { s += "\nVCA: \(node.vcaNames.joined(separator: ", "))" }
            if !node.inserts.isEmpty { s += "\nInserts: \(node.inserts.joined(separator: ", "))" }
            if node.fromHiddenCache { s += "\n(hidden track — routing read earlier)" }
            if let o = node.objectPath {
                s += "\nAtmos object: \(o) — " + (node.objectActive == true ? "ACTIVE (object)" : "inactive, signal goes to bed/bus")
            }
            if let g = node.atmosGroup { s += "\nAtmos group: \(g)" }
            for k in node.sends.keys.sorted() {
                s += "\nSend \(k): \(node.sends[k]!)" + ((node.sendStates[k] ?? "").contains("pre") ? " [pre-fader]" : " [post-fader]")
                if let st = node.sendStates[k], !st.isEmpty { s += " (\(st))" }
            }
        }
        return s
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9 * scale, weight: .bold)).foregroundStyle(.black)
            .frame(width: 14 * scale, height: 14 * scale).background(RoundedRectangle(cornerRadius: 3 * scale).fill(c))
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: SessionModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No routing found yet").font(.title3.weight(.semibold))
            Group {
                if !model.ptslOK { Text("Start Pro Tools and open a session.") }
                else if !model.axTrusted { Text("Give PT Wiregram Accessibility access (see the bar at the top).") }
                else if model.axWindow.isEmpty { Text("Open the Mix window in Pro Tools (Window ▸ Mix, ⌘=) so I/O and sends are visible.") }
                else { Text("Turn off ‘Routed Only’ to see all tracks.") }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Table

struct TableView: View {
    @EnvironmentObject var model: SessionModel
    var scale: CGFloat = 1
    var body: some View {
        let q = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? model.rows : model.rows.filter {
            "\($0.name) \($0.input) \($0.output) \($0.sends) \($0.groups)".lowercased().contains(q)
        }
        Table(rows) {
            TableColumn("#") { Text("\($0.index)").monospacedDigit().foregroundStyle(.secondary) }.width(36)
            TableColumn("Track", value: \.name).width(min: 140, ideal: 200)
            TableColumn("Type", value: \.type).width(min: 80, ideal: 110)
            TableColumn("Input", value: \.input).width(min: 90, ideal: 140)
            TableColumn("Output", value: \.output).width(min: 90, ideal: 160)
            TableColumn("Sends", value: \.sends)
            TableColumn("Groups", value: \.groups).width(min: 60, ideal: 120)
            TableColumn("Inserts", value: \.inserts).width(min: 80, ideal: 180)
            TableColumn("VCA", value: \.vca).width(min: 50, ideal: 90)
        }
        .font(.system(size: 13 * scale))
    }
}

extension GraphNode {
    /// Dummy node used only to compute a frame at a given row.
    static func probe(row: Double) -> GraphNode {
        var n = GraphNode(id: "", kind: .track, name: "", typeLabel: "", color: .clear, inactive: false,
                          muted: false, soloed: false, index: 0)
        n.row = row
        return n
    }
}


// MARK: - Legend

struct LegendView: View {
    let split: Bool
    var sends = true
    var atmos = false
    var collapsed = false
    var onClose: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                row("Output", dash: [])
                if sends {
                    if split {
                        row("Send post-fader", dash: [7, 4])
                        row("Send pre-fader", dash: [6, 6], pre: true)
                    } else {
                        row("Send", dash: [7, 4])
                    }
                    row("Muted / inactive send", dash: [7, 4], opacity: 0.3)
                }
                if atmos { row("Atmos: inactive side (bed or object)", dash: [2, 5], width: 1.1, opacity: 0.4) }
            }
            if collapsed {
                VStack(alignment: .leading, spacing: 4) { stackRow("Collapsed tracks") }
            }
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain)
                .help("Hide legend (View ▸ Show Legend)")
        }
        .font(.system(size: 10.5))
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private func row(_ t: String, dash: [CGFloat], width: CGFloat = 1.6, opacity: Double = 1, pre: Bool = false) -> some View {
        HStack(spacing: 8) {
            Canvas { ctx, size in
                var p = Path(); p.move(to: CGPoint(x: 1, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                ctx.stroke(p, with: .color(.primary.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: dash))
                if pre {
                    ctx.stroke(p, with: .color(GraphContent.preBlue), style: StrokeStyle(lineWidth: width + 1.6, lineCap: .round, dash: [0.01, 12], dashPhase: -9))
                }
            }
            .frame(width: 34, height: 8)
            Text(t).foregroundStyle(.secondary)
        }
    }

    private func stackRow(_ t: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        return HStack(spacing: 8) {
            ZStack {
                shape.strokeBorder(Color.secondary, lineWidth: 1).offset(x: 2, y: -2)
                shape.fill(Color(nsColor: .controlBackgroundColor))
                shape.strokeBorder(Color.secondary, lineWidth: 1)
            }
            .frame(width: 28, height: 11)
            .frame(width: 34)
            Text(t).foregroundStyle(.secondary)
        }
    }
}

// MARK: - VCA view

struct VCAView: View {
    @EnvironmentObject var model: SessionModel
    var scale: CGFloat = 1

    var body: some View {
        let infos = model.vcaInfos
        if infos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "slider.vertical.3").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("No VCAs found").font(.title3.weight(.semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "slider.vertical.3").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("\(infos.count) VCAs found").font(.title3.weight(.semibold))
                Text("Which tracks a VCA controls follows from the groups. Read those first.").foregroundStyle(.secondary)
                Button("Read Groups") { model.readGroups() }
                if !model.groupStatus.isEmpty { Text(model.groupStatus).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let colW = 230 * scale, gap: CGFloat = 14
                let cols = max(1, Int((geo.size.width - 32 + gap) / (colW + gap)))
                // Cards go to the shortest column (by track count), like a masonry layout.
                let all: [(String, AnyView, Int)] = infos.map { v in
                    (v.id, AnyView(card(title: v.name, color: v.color,
                                        subtitle: v.groups.isEmpty ? "No group assigned" : "Group: " + v.groups.joined(separator: ", "),
                                        nested: v.nestedVCAs, tracks: v.members)), v.members.count + 3)
                } + [("none", AnyView(card(title: "Not under a VCA", color: .secondary, subtitle: "Audio, aux and instrument tracks",
                                             nested: [], tracks: model.tracksWithoutVCA, muted: true)), model.tracksWithoutVCA.count + 3)]
                let columns: [[(String, AnyView, Int)]] = {
                    var c = Array(repeating: [(String, AnyView, Int)](), count: cols)
                    var h = Array(repeating: 0, count: cols)
                    for item in all { let i = h.indices.min { h[$0] < h[$1] }!; c[i].append(item); h[i] += item.2 }
                    return c
                }()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(columns.indices, id: \.self) { ci in
                            VStack(spacing: gap) {
                                ForEach(columns[ci], id: \.0) { $0.1 }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func card(title: String, color: Color, subtitle: String, nested: [String], tracks: [PTTrack], muted: Bool = false) -> some View {
        let k = scale
        return VStack(alignment: .leading, spacing: 6 * k) {
            HStack(spacing: 8 * k) {
                RoundedRectangle(cornerRadius: 2 * k).fill(color).frame(width: 6 * k, height: 26 * k)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14 * k, weight: .bold))
                    Text(subtitle).font(.system(size: 10 * k)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(tracks.count)").font(.system(size: 12 * k, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7 * k).padding(.vertical, 2 * k)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if !nested.isEmpty {
                Text("Also controls: " + nested.joined(separator: ", ")).font(.system(size: 10.5 * k)).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(tracks, id: \.id) { t in
                HStack(spacing: 7 * k) {
                    RoundedRectangle(cornerRadius: 1.5 * k).fill(Color(argbHex: t.color)).frame(width: 4 * k, height: 14 * k)
                    Text(t.name).font(.system(size: 12 * k)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SessionModel.typeLabel(t.type, t.format)).font(.system(size: 9.5 * k)).foregroundStyle(.secondary)
                }
                .opacity(t.isInactive ? 0.5 : 1)
            }
            if tracks.isEmpty { Text("—").foregroundStyle(.secondary) }
        }
        .padding(12 * k)
        .background(RoundedRectangle(cornerRadius: 10 * k).fill(Color(nsColor: .controlBackgroundColor).opacity(muted ? 0.6 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 10 * k).strokeBorder(Color.secondary.opacity(0.25)))
    }
}


// MARK: - Appearance

enum Appearance {
    /// Applies "system" / "light" / "dark" to the whole app (also AppKit-drawn controls).
    static func apply(_ v: String) {
        NSApp.appearance = v == "light" ? NSAppearance(named: .aqua) : v == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

extension Color {
    /// Very dark track colours (e.g. #2A2A2A) disappear on a dark background: lift them
    /// towards a readable brightness while keeping their hue.
    func readable(dark: Bool) -> Color {
        guard dark, let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        guard lum < 0.42 else { return self }
        let t = min(0.75, (0.42 - lum) / 0.42 * 0.9 + 0.15)
        return Color(red: c.redComponent + (1 - c.redComponent) * t,
                     green: c.greenComponent + (1 - c.greenComponent) * t,
                     blue: c.blueComponent + (1 - c.blueComponent) * t)
    }

    /// Black or white, whichever reads best on this colour.
    var contrastText: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .primary }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.55 ? .black : .white
    }
}


enum Palette {
    /// Graph background: a touch darker than the blocks in light mode, darker than them in dark mode.
    static func canvas(_ dark: Bool) -> Color { dark ? Color(white: 0.105) : Color(white: 0.915) }
    static func block(_ dark: Bool) -> Color { dark ? Color(white: 0.215) : Color.white }
}
