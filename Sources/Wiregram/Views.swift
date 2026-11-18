import SwiftUI

enum Layout {
    static let nodeW: CGFloat = 210
    static let nodeH: CGFloat = 34
    static let colGap: CGFloat = 130
    static let focusColGap: CGFloat = 50
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

struct ContentView: View {
    @EnvironmentObject var model: SessionModel
    @State private var tab = 0
    @State private var zoom: CGFloat = 1.0
    @State private var tableScale: CGFloat = 1.0
    @AppStorage("appearance") private var appearance = "system"
    @State private var scrollMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            if !model.axTrusted { accessBanner }
            Group {
                switch tab {
                case 0: GraphView(zoom: $zoom)
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
                    Label("Graaf", systemImage: "point.3.connected.trianglepath.dotted").tag(0)
                    Label("Tabel", systemImage: "tablecells").tag(1)
                    Label("VCA's", systemImage: "slider.vertical.3").tag(2)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Toggle(isOn: $model.onlyRouted) { Label("Alleen gerouteerd", systemImage: "line.3.horizontal.decrease.circle") }
                    .labelStyle(.titleAndIcon)
                    .help("Verberg tracks zonder routing-informatie")
                Toggle(isOn: $model.hideInactive) { Label("Verberg inactieve tracks", systemImage: "moon.zzz") }
                    .labelStyle(.titleAndIcon)
                    .help("Verberg inactieve tracks")
                Toggle(isOn: Binding(get: { !model.hideHidden }, set: { model.hideHidden = !$0 })) {
                    Label("Toon verborgen", systemImage: "eye.slash")
                }
                .labelStyle(.titleAndIcon)
                .help("Toon verborgen tracks. Hun routing komt uit ‘Inlezen ▸ Verborgen tracks’.")
                Toggle(isOn: $model.showDevices) { Label("I/O devices", systemImage: "cable.connector") }
                    .labelStyle(.titleAndIcon)
                    .help("Toon hardware-inputs (Input-tab van I/O Setup) en output-paden. Lees de I/O in via ‘Inlezen ▸ I/O-instellingen’.")
                Menu {
                    Toggle("Sends", isOn: $model.showSends)
                    Toggle("Pre- en post-fader sends onderscheiden", isOn: $model.splitPrePost).disabled(!model.showSends)
                    Toggle("Groepeer bronnen op groep", isOn: $model.groupByGroups).disabled(model.groups.isEmpty)
                    Button("Herstel blokposities") { model.resetRowOverrides() }.disabled(!model.hasRowOverrides)
                    Divider()
                    Picker("Uiterlijk", selection: $appearance) {
                        Text("Volg systeem").tag("system")
                        Text("Licht").tag("light")
                        Text("Donker").tag("dark")
                    }
                    Divider()
                    Text("Toon in de blokken")
                    Toggle("Groepsnamen", isOn: $model.showGroupNames)
                    Toggle("Inserts", isOn: $model.showInserts)
                    Toggle("VCA-toewijzing", isOn: $model.showVCA)
                } label: { Label("Weergave", systemImage: "slider.horizontal.3") }
                    .labelStyle(.titleAndIcon)
                Menu {
                    Button("Groepen…") { model.readGroups() }
                    if !model.groupStatus.isEmpty { Text(model.groupStatus) }
                    Divider()
                    Button("Verborgen tracks…") { model.readHiddenTracks() }
                    if !model.hiddenStatus.isEmpty { Text(model.hiddenStatus) }
                    Divider()
                    Button("I/O-instellingen…") { model.readIO() }
                    if !model.ioReadStatus.isEmpty { Text(model.ioReadStatus) }
                } label: { Label("Inlezen", systemImage: "square.and.arrow.down.on.square") }
                    .labelStyle(.titleAndIcon)
                    .help("Groepen: selecteert kort elke track via de Pro Tools API en zet je selectie terug. Verborgen tracks: maakt ze kort zichtbaar, leest de routing en verbergt ze weer. I/O: opent Setup ▸ I/O, leest de Input- en Output-tab en sluit met Cancel. Alles wordt per sessie onthouden.")
                if tab == 0 {
                    Button { zoom = max(0.3, zoom - 0.15) } label: { Label("Uitzoomen", systemImage: "minus.magnifyingglass") }
                    Button { zoom = min(2.5, zoom + 0.15) } label: { Label("Inzoomen", systemImage: "plus.magnifyingglass") }
                }
                Button { model.refreshNow() } label: { Label("Opnieuw scannen", systemImage: "arrow.clockwise") }
                    .help("Mix-venster opnieuw scannen")
            }
        }
        .searchable(text: $model.search, prompt: "Zoek track of bus")
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

    private var accessBanner: some View {
        HStack {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("PT Wiregram heeft Accessibility-toegang nodig om de I/O- en send-routing uit het Pro Tools Mix-venster te lezen.")
            Spacer()
            Button("Toegang geven…") { model.requestAccessibility() }
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
            Text("\(model.tracks.count) tracks · \(model.edges.count) verbindingen")
            if let d = model.lastUpdate { Text(d, style: .time).monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var axText: String {
        if !model.axTrusted { return "Geen Accessibility-toegang" }
        if model.axWindow.isEmpty { return "Open het Mix-venster in Pro Tools (⌘=)" }
        return "Routing uit: \(model.axWindow)"
    }
}

// MARK: - Graph

struct GraphView: View {
    @EnvironmentObject var model: SessionModel
    @Environment(\.colorScheme) private var scheme
    @Binding var zoom: CGFloat
    @GestureState private var pinch: CGFloat = 1
    @State private var viewSize: CGSize = .zero
    @State private var zoomBeforeFocus: CGFloat?
    @State private var monitor: Any?

    var body: some View {
        let hl = model.selectedID ?? model.hoveredID
        let lit: Set<String>? = model.focusID == nil ? hl.map { model.chain(of: $0) } : nil
        let z = zoom * pinch

        if model.nodes.isEmpty {
            EmptyStateView()
        } else {
            let content = GraphContent(nodes: model.nodes, edges: model.edges,
                                       groups: model.groupByGroups && model.focusID == nil ? model.groups : [],
                                       colGap: model.focusID == nil ? Layout.colGap : Layout.focusColGap,
                                       showGroupNames: model.showGroupNames, showInserts: model.showInserts,
                                       showVCA: model.showVCA, splitPrePost: model.splitPrePost,
                                       scale: z, lit: lit,
                                       query: model.search, selectedID: model.selectedID ?? model.focusID,
                                       onHover: { id, on in
                                           if on { model.hoveredID = id } else if model.hoveredID == id { model.hoveredID = nil }
                                       },
                                       onTap: { id in model.selectedID = model.selectedID == id ? nil : id },
                                       onMove: { id, rows in model.moveNode(id, byRows: rows) })
            let size = content.size
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        content
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = nil }
                            // In focus mode, centre the (fitted) routing in the window.
                            .frame(minWidth: model.focusID == nil ? 0 : geo.size.width,
                                   minHeight: model.focusID == nil ? 0 : geo.size.height)
                            .id("graph-origin")
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
                .onEnded { zoom = min(2.5, max(0.2, zoom * $0)) })
            .background(Palette.canvas(scheme == .dark))
            .overlay(alignment: .bottomLeading) {
                if model.showSends { LegendView(split: model.splitPrePost, atmos: model.edges.contains(where: \.inactiveRoute)) }
            }
            .background {
                // Esc also leaves focus mode (invisible; no button on screen).
                Button("") { model.focusID = nil }.keyboardShortcut(.cancelAction).opacity(0).disabled(model.focusID == nil)
            }
            .onAppear(perform: installMonitor)
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        }
    }

    /// Size of the graph as the model is *now* (closures above captured an older value).
    private var currentSize: CGSize {
        GraphContent(nodes: model.nodes, edges: model.edges,
                     colGap: model.focusID == nil ? Layout.colGap : Layout.focusColGap,
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

    /// Right-click on a node focuses it; a second right-click anywhere (or Esc) leaves focus mode.
    private func installMonitor() {
        guard monitor == nil else { return }
        let model = self.model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            if model.focusID != nil, event.window?.isKeyWindow == true {
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
    @State private var dragID: String?
    @State private var dragDY: CGFloat = 0

    var maxCol: Int { nodes.map(\.column).max() ?? 0 }
    var size: CGSize {
        let maxRow = nodes.map(\.row).max() ?? 0
        return CGSize(width: Layout.pad * 2 + CGFloat(maxCol + 1) * (Layout.nodeW + colGap) - colGap,
                      height: Layout.pad * 2 + 26 + CGFloat(maxRow + 1) * (nodeH + Layout.rowGap))
    }

    private func header(_ c: Int) -> String {
        let kinds = Set(nodes.filter { $0.column == c }.map(\.kind))
        if kinds == [.deviceIn] { return "Hardware-inputs" }
        if kinds == [.deviceOut] {
            return nodes.contains { $0.column == c && $0.id == "d:renderer" } ? "Atmos-renderer & hardware-outputs" : "Hardware-outputs"
        }
        if kinds == [.endpoint] { return "Output-paden" }
        let first = nodes.contains { $0.kind == .deviceIn } ? 1 : 0
        return c == first ? "Bronnen" : "Bussen · niveau \(c - first)"
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
        if showGroupNames { l.append("Groep: " + (n.groupNames.isEmpty ? "—" : n.groupNames.joined(separator: ", "))) }
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

    var body: some View {
        let k = scale
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let size = self.size
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
                // Several connections between the same two blocks (e.g. output + post send +
                // pre send) get their own parallel lane instead of sharing one line.
                // Without the pre/post split, all sends between two blocks become one line.
                var drawEdges: [GraphEdge] = []
                if splitPrePost {
                    drawEdges = edges
                } else {
                    var seen: [String: Int] = [:]
                    for e in edges {
                        guard e.isSend else { drawEdges.append(e); continue }
                        let key = e.from + ">" + e.to
                        if let i = seen[key] {
                            drawEdges[i].muted = drawEdges[i].muted && e.muted // muted only if all are
                        } else {
                            var c = e; c.isPre = false
                            seen[key] = drawEdges.count
                            drawEdges.append(c)
                        }
                    }
                }
                var lanes: [String: [GraphEdge]] = [:]
                for e in drawEdges { lanes[e.from + ">" + e.to, default: []].append(e) }
                func rank(_ e: GraphEdge) -> Int { !e.isSend ? 0 : (e.isPre ? 2 : 1) }
                for key in lanes.keys { lanes[key]!.sort { (rank($0), $0.label) < (rank($1), $1.label) } }
                // Every outgoing connection of a block also gets its own start point, ordered by
                // where it goes, so a line (and its PRE tag) is unambiguous at the source.
                var outgoing: [String: [GraphEdge]] = [:]
                for e in drawEdges where byID[e.to] != nil { outgoing[e.from, default: []].append(e) }
                for key in outgoing.keys {
                    outgoing[key]!.sort { x, y in
                        let ry = byID[x.to]!.row, sy = byID[y.to]!.row
                        return ry == sy ? (rank(x), x.label) < (rank(y), y.label) : ry < sy
                    }
                }
                for e in drawEdges {
                    guard let a = byID[e.from], let b = byID[e.to] else { continue }
                    let fa = rawFrame(a), fb = rawFrame(b)
                    let group = lanes[e.from + ">" + e.to] ?? [e]
                    let n = group.count
                    let i = group.firstIndex(of: e) ?? 0
                    let spacing = n > 1 ? min(10, (nodeH - 8) / CGFloat(n - 1)) : 0
                    let off = (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
                    let outs = outgoing[e.from] ?? [e]
                    let oi = outs.firstIndex(of: e) ?? 0
                    let ospacing = outs.count > 1 ? min(8, (nodeH - 8) / CGFloat(outs.count - 1)) : 0
                    let p0 = CGPoint(x: fa.maxX, y: fa.midY + (CGFloat(oi) - CGFloat(outs.count - 1) / 2) * ospacing)
                    let p1 = CGPoint(x: fb.minX, y: fb.midY + off)
                    var path = Path()
                    path.move(to: p0)
                    if p1.x > p0.x {
                        let dx = max(40, (p1.x - p0.x) * 0.5)
                        path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
                    } else { // feedback loop: route around
                        let dx: CGFloat = 60
                        path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y + 40), control2: CGPoint(x: p1.x - dx, y: p1.y + 40))
                    }
                    let on = lit == nil || (lit!.contains(e.from) && lit!.contains(e.to))
                    let color = (a.kind == .track ? a.color : Color.gray).readable(dark: dark)
                    let alpha = on ? (e.inactiveRoute ? 0.28 : e.muted ? 0.3 : (e.isSend ? 0.75 : 0.95)) : 0.07
                    let w: CGFloat = on && lit != nil ? 2.5 : 1.6
                    let pre = splitPrePost && e.isSend && e.isPre
                    let dash: [CGFloat] = e.inactiveRoute ? [2, 5] : (!e.isSend ? [] : (pre ? [6, 6] : [7, 4]))
                    ctx.stroke(path, with: .color(color.opacity(alpha)),
                               style: StrokeStyle(lineWidth: e.inactiveRoute ? 1.1 : w, lineCap: .butt, dash: dash))
                    if pre {
                        // Pro Tools marks pre-fader sends in blue: blue dots in the gaps of the dashes.
                        ctx.stroke(path, with: .color(Self.preBlue.opacity(on ? (e.muted ? 0.45 : 1) : 0.07)),
                                   style: StrokeStyle(lineWidth: w + 1.6, lineCap: .round, dash: [0.01, 12], dashPhase: -9))
                    }
                    var head = Path()
                    head.move(to: p1)
                    head.addLine(to: CGPoint(x: p1.x - 7, y: p1.y - 4))
                    head.addLine(to: CGPoint(x: p1.x - 7, y: p1.y + 4))
                    head.closeSubpath()
                    ctx.fill(head, with: .color(color.opacity(on ? 0.95 : 0.07)))
                    if splitPrePost && e.isSend && e.isPre && on {
                        // Small "PRE" tag right after the source block (one per lane, no overlap).
                        let tag = ctx.resolve(Text("PRE").font(.system(size: 6.5, weight: .heavy)).foregroundColor(.white))
                        let ts = tag.measure(in: CGSize(width: 40, height: 12))
                        let r = CGRect(x: p0.x + 5, y: p0.y - ts.height / 2 - 0.5, width: ts.width + 4, height: ts.height + 1)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Self.preBlue.opacity(e.muted ? 0.55 : 1)))
                        ctx.draw(tag, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
                    }
                }
            }
            .frame(width: size.width * k, height: size.height * k)
            .allowsHitTesting(false)

            ForEach(nodes) { n in
                let f = frame(n)
                let match = !q.isEmpty && (n.name.lowercased().contains(q)
                    || (n.input ?? "").lowercased().contains(q)
                    || n.outputs.contains { $0.lowercased().contains(q) })
                NodeView(node: n, selected: selectedID == n.id, highlighted: match,
                         dimmed: (lit.map { !$0.contains(n.id) } ?? false) || (!q.isEmpty && !match), scale: k,
                         info: infoLines(n))
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

struct NodeView: View {
    let node: GraphNode
    let selected: Bool
    let highlighted: Bool
    let dimmed: Bool
    var scale: CGFloat = 1
    var info: [String] = []
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = scale
        HStack(spacing: 7 * k) {
            switch node.kind {
            case .track: RoundedRectangle(cornerRadius: 2 * k).fill(node.color.readable(dark: scheme == .dark)).frame(width: 5 * k).padding(.vertical, 5 * k)
            case .endpoint: Image(systemName: "arrow.right.circle").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            case .deviceOut: Image(systemName: "hifispeaker.fill").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            case .deviceIn: Image(systemName: "mic.fill").font(.system(size: 11 * k)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).font(.system(size: 12 * k, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 9.5 * k)).foregroundStyle(.secondary).lineLimit(1)
                ForEach(Array(info.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 9 * k)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .frame(height: Layout.infoLineH * k, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            if node.objectPath != nil, let on = node.objectActive {
                Text(on ? "OBJ" : "BED").font(.system(size: 8 * k, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 4 * k).frame(height: 14 * k)
                    .background(RoundedRectangle(cornerRadius: 3 * k).fill(on ? Color.orange : Color.teal))
                    .help(on ? "Signaal gaat naar Atmos-object \(node.objectPath!)" : "Signaal gaat naar de bed/bus-output")
            }
            if node.muted { badge("M", .yellow) }
            if node.soloed { badge("S", .green) }
        }
        .padding(.horizontal, 7 * k)
        .background(
            RoundedRectangle(cornerRadius: 6 * k)
                .fill(node.kind == .track ? Palette.block(scheme == .dark)
                      : node.kind == .endpoint ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6 * k)
                .strokeBorder(selected ? Color.accentColor : (highlighted ? .orange : Color.secondary.opacity(0.35)),
                              lineWidth: (selected || highlighted ? 2 : 0.8) * max(1, k))
        )
        .opacity(dimmed ? 0.25 : (node.inactive ? 0.55 : 1))
        .shadow(color: .black.opacity(0.12), radius: 1.5 * k, y: 1 * k)
        .help(tooltip)
    }

    private var subtitle: String {
        if node.kind == .endpoint { return node.typeLabel == "Output" ? "Output-pad" : node.typeLabel }
        if node.kind == .deviceIn || node.kind == .deviceOut { return node.detail }
        if let i = node.input, !i.isEmpty { return "\(node.typeLabel)  ·  in: \(i)" }
        return node.typeLabel
    }

    private var tooltip: String {
        var s = node.name
        if node.kind == .track {
            s += "\nType: \(node.typeLabel)"
            s += "\nInput: \(node.input ?? "—")"
            s += "\nOutput: \(node.outputs.isEmpty ? "—" : node.outputs.joined(separator: ", "))"
            if !node.groupNames.isEmpty { s += "\nGroepen: \(node.groupNames.joined(separator: ", "))" }
            if !node.vcaNames.isEmpty { s += "\nVCA: \(node.vcaNames.joined(separator: ", "))" }
            if !node.inserts.isEmpty { s += "\nInserts: \(node.inserts.joined(separator: ", "))" }
            if node.fromHiddenCache { s += "\n(verborgen track — routing eerder ingelezen)" }
            if let o = node.objectPath {
                s += "\nAtmos-object: \(o) — " + (node.objectActive == true ? "ACTIEF (object)" : "inactief, signaal gaat naar bed/bus")
            }
            if let g = node.atmosGroup { s += "\nAtmos-groep: \(g)" }
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
            Text("Nog geen routing gevonden").font(.title3.weight(.semibold))
            Group {
                if !model.ptslOK { Text("Start Pro Tools en open een sessie.") }
                else if !model.axTrusted { Text("Geef PT Wiregram Accessibility-toegang (zie balk bovenaan).") }
                else if model.axWindow.isEmpty { Text("Open het Mix-venster in Pro Tools (Window ▸ Mix, ⌘=) zodat I/O en sends zichtbaar zijn.") }
                else { Text("Zet ‘Alleen gerouteerd’ uit om alle tracks te zien.") }
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
            TableColumn("Groepen", value: \.groups).width(min: 60, ideal: 120)
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
    var atmos = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Output", dash: [])
            if split {
                row("Send post-fader", dash: [7, 4])
                row("Send pre-fader", dash: [6, 6], pre: true)
            } else {
                row("Send", dash: [5, 4])
            }
            row("Gemute / inactieve send", dash: [5, 4], opacity: 0.3)
            if atmos { row("Atmos: niet-actieve kant (bed of object)", dash: [2, 5], width: 1.1, opacity: 0.4) }
        }
        .font(.system(size: 10.5))
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .allowsHitTesting(false)
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
                Text("Geen VCA's gevonden").font(.title3.weight(.semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "slider.vertical.3").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("\(infos.count) VCA's gevonden").font(.title3.weight(.semibold))
                Text("Welke tracks onder een VCA vallen, volgt uit de groepen. Lees die eerst in.").foregroundStyle(.secondary)
                Button("Groepen inlezen") { model.readGroups() }
                if !model.groupStatus.isEmpty { Text(model.groupStatus).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230 * scale), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(infos) { v in
                        card(title: v.name, color: v.color,
                             subtitle: v.groups.isEmpty ? "Geen groep toegewezen" : "Groep: " + v.groups.joined(separator: ", "),
                             nested: v.nestedVCAs, tracks: v.members)
                    }
                    card(title: "Niet onder een VCA", color: .secondary, subtitle: "Audio-, aux- en instrumenttracks",
                         nested: [], tracks: model.tracksWithoutVCA, muted: true)
                }
                .padding(16)
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
                Text("Stuurt ook: " + nested.joined(separator: ", ")).font(.system(size: 10.5 * k)).foregroundStyle(.secondary)
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
}


enum Palette {
    /// Graph background: a touch darker than the blocks in light mode, darker than them in dark mode.
    static func canvas(_ dark: Bool) -> Color { dark ? Color(white: 0.105) : Color(white: 0.915) }
    static func block(_ dark: Bool) -> Color { dark ? Color(white: 0.215) : Color.white }
}
