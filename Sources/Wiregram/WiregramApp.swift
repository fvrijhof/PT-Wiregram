import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // Diagnostics: `Wiregram --dump-ax <file>` writes Pro Tools' accessibility tree.
        if let i = args.firstIndex(of: "--dump-ax"), i + 1 < args.count {
            ProToolsAX.dumpTree(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // `Wiregram --routing-test <file>` writes the parsed routing + timings.
        if let i = args.firstIndex(of: "--routing-test"), i + 1 < args.count {
            let ax = ProToolsAX()
            var out = ""
            var t = Date()
            var r = ax.readRouting(forceRescan: true)
            out += "scan: \(Date().timeIntervalSince(t))s window=\(ax.windowUsed) strips=\(r.count)\n"
            t = Date(); r = ax.readRouting()
            out += "poll: \(Date().timeIntervalSince(t))s\n"
            for (k, v) in ProToolsAX.readIOSetup() { out += "IO \(k): \(v.summary)\n" }
            for (k, v) in r.sorted(by: { $0.key < $1.key }) {
                out += "\(k) | in=\(v.input ?? "-") | out=\(v.outputs) \(v.outputParents) | sends=\(v.sends.sorted { $0.key < $1.key }) \(v.sendStates)\n"
            }
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        // `Wiregram --graph-test <routing.json>`: build the graph from live PTSL + JSON routing.
        if let i = args.firstIndex(of: "--graph-test"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))) as? [String: [String: Any]] ?? [:]
                var routing: [String: AXRouting] = [:]
                for (k, v) in json {
                    routing[k] = AXRouting(input: v["in"] as? String, outputs: v["out"] as? [String] ?? [],
                                           outputParents: v["parents"] as? [String: String] ?? [:],
                                           sends: v["sends"] as? [String: String] ?? [:],
                                           sendStates: ["A": "pre is active and muted", "B": "", "C": "pre is active", "D": ""],
                                           inserts: k.hasPrefix("DX") ? ["FabFilter Pro-Q 3", "dxRevive Pro"] : [])
                }
                let m = SessionModel()
                if args.contains("--fake-io") {
                    m.injectIO([
                        "input:mic in 1": IOPathInfo(name: "Mic in 1", direction: "Input", format: "Mono", device: "192 Digital I/O #1", channels: "", active: true),
                        "input:mic in 2": IOPathInfo(name: "Mic in 2", direction: "Input", format: "Mono", device: "192 Digital I/O #1", channels: "", active: false),
                        "output:output": IOPathInfo(name: "Output", direction: "Output", format: "7.1.4", device: "192 Digital I/O #1", channels: "", active: true),
                    ])
                }
                m.showDevices = args.contains("--devices")
                if args.contains("--fake-groups") {
                    let ts = (try? PTSLClient().trackList()) ?? []
                    m.injectGroups([
                        .init(id: "a", name: "DX group", vca: "DX VCA", members: ts.map(\.name).filter { $0.hasPrefix("DX ") }),
                        .init(id: "c", name: "FX group", vca: "FX VCA", members: ts.map(\.name).filter { $0.hasPrefix("FX ") }),
                        .init(id: "d", name: "AM group", vca: "AM VCA", members: ts.map(\.name).filter { $0.hasPrefix("AM ") }),
                    ])
                    m.groupByGroups = true
                }
                m.inject(tracks: (try? PTSLClient().trackList()) ?? [], routing: routing)
                if let fi = args.firstIndex(of: "--focus"), fi + 1 < args.count {
                    m.focusID = m.nodes.first { $0.name == args[fi + 1] }?.id
                }
                if let mi = args.firstIndex(of: "--move"), mi + 2 < args.count, let d = Double(args[mi + 2]),
                   let id = m.nodes.first(where: { $0.name == args[mi + 1] })?.id {
                    m.moveNode(id, byRows: d)
                }
                let byID = Dictionary(uniqueKeysWithValues: m.nodes.map { ($0.id, $0) })
                for n in m.nodes.sorted(by: { ($0.column, $0.row) < ($1.column, $1.row) }) {
                    print("col \(n.column) row \(Int(n.row))  \(n.name)  [\(n.typeLabel)]")
                }
                if let png = args.firstIndex(of: "--png").map({ args[$0 + 1] }) {
                    let zf = args.firstIndex(of: "--zoom").flatMap { Double(args[$0 + 1]) } ?? 1
                    let view = GraphContent(nodes: m.nodes, edges: m.edges, groups: m.groupByGroups ? m.groups : [],
                                            colGap: m.focusID == nil ? Layout.colGap : Layout.focusColGap,
                                            showGroupNames: args.contains("--info"), showInserts: args.contains("--info"),
                                            showVCA: args.contains("--info"), splitPrePost: true, scale: CGFloat(zf),
                                            lit: args.contains("--select") ? m.chain(of: m.nodes.first { $0.name == "SFX Aux" }?.id ?? "") : nil)
                        .background(Palette.canvas(args.contains("--dark")))
                        .environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
                    if args.contains("--dark") { NSAppearance.current = NSAppearance(named: .darkAqua) }
                    let r = ImageRenderer(content: view)
                    r.scale = 1.5
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: png))
                    }
                }
                for e in m.edges { print("\(byID[e.from]?.name ?? e.from) -> \(byID[e.to]?.name ?? e.to) \(e.isSend ? "(send \(e.label))" : "")") }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--io-probe"), i + 1 < args.count {
            ProToolsAX.probeIOSetup(to: URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        if let i = args.firstIndex(of: "--group-test"), i + 1 < args.count {
            var out = ""
            let c = PTSLClient()
            let before = (try? c.selectedTrackNames()) ?? []
            out += "selection before: \(before)\n"
            let t = Date()
            do {
                let names = ((try? c.trackList()) ?? []).map(\.name)
                for g in try ProToolsAX.readGroups(ptsl: c, trackNames: names) {
                    out += "\(g.id) | \(g.name) | vca=\(g.vca ?? "-") | \(g.members.count): \(g.members)\n"
                }
            } catch { out += "error: \(error)\n" }
            out += "took \(Date().timeIntervalSince(t))s\nselection after: \((try? c.selectedTrackNames()) ?? [])\n"
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--io-dialog-test"), i + 1 < args.count {
            var out = ""
            do { for (k, v) in try ProToolsAX.readIOViaDialog().sorted(by: { $0.key < $1.key }) { out += "\(k): \(v.summary)\n" } }
            catch { out += "error: \(error.localizedDescription)\n" }
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8); exit(0)
        }
        if let i = args.firstIndex(of: "--hidden-test"), i + 1 < args.count {
            var out = ""
            let c = PTSLClient()
            let ts = (try? c.trackList()) ?? []
            let names = ts.filter { $0.isHidden && SessionModel.routableTypes.contains($0.type) }.map(\.name)
            let unhide = ts.filter(\.isHiddenExplicitly).map(\.name)
            let open = SessionModel.closedAncestors(of: ts.filter { $0.isHidden && SessionModel.routableTypes.contains($0.type) }, in: ts)
            out += "hidden: \(names.count), toggled: \(unhide), open: \(open)\n"
            do {
                for (k, v) in try ProToolsAX.readHiddenRouting(ptsl: c, names: names, unhide: unhide, openFolders: open).sorted(by: { $0.key < $1.key }) {
                    out += "\(k) | in=\(v.input ?? "-") | out=\(v.outputs) | sends=\(v.sends)\n"
                }
            } catch { out += "error: \(error.localizedDescription)\n" }
            let after = ((try? c.trackList()) ?? []).filter { $0.isHiddenExplicitly }.map(\.name)
            out += "hidden after: \(after.count) (before \(ts.filter { $0.isHiddenExplicitly }.count))\n"
            let closedAfter = ((try? c.trackList()) ?? []).filter { open.contains($0.name) && $0.isOpen }.map(\.name)
            out += "folders still open: \(closedAfter)\n"
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8); exit(0)
        }
        if let i = args.firstIndex(of: "--atmos-dump"), i + 1 < args.count {
            ProToolsAX.atmosDump(to: URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        // `Wiregram --live-graph <png> <txt>`: render the live session (PTSL + AX + I/O dialog).
        if let i = args.firstIndex(of: "--live-graph"), i + 2 < args.count {
            MainActor.assumeIsolated {
                let m = SessionModel()
                let io = (try? ProToolsAX.readIOViaDialog()) ?? [:]
                m.injectIO(io)
                m.showDevices = true
                m.inject(tracks: (try? PTSLClient().trackList()) ?? [], routing: ProToolsAX().readRouting(forceRescan: true))
                var out = "io: \(io.values.map { "\($0.direction):\($0.name)" }.sorted())\n"
                let byID = Dictionary(uniqueKeysWithValues: m.nodes.map { ($0.id, $0) })
                for n in m.nodes { out += "node col \(n.column) \(n.name) [\(n.typeLabel)] obj=\(n.objectPath ?? "-") active=\(String(describing: n.objectActive))\n" }
                for e in m.edges { out += "\(byID[e.from]?.name ?? e.from) -> \(byID[e.to]?.name ?? e.to)\(e.inactiveRoute ? " (inactive route)" : "")\(e.isSend ? " send" : "")\n" }
                try? out.write(toFile: args[i + 2], atomically: true, encoding: .utf8)
                let view = GraphContent(nodes: m.nodes, edges: m.edges, splitPrePost: true, scale: 1.4)
                    .background(Palette.canvas(false))
                let r = ImageRenderer(content: view)
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: args[i + 1])) }
            }
            exit(0)
        }
        // `Wiregram --ptsl-test` prints the PTSL track list.
        if args.contains("--ptsl-test") {
            let c = PTSLClient()
            do {
                print("Session:", try c.sessionName())
                for t in try c.trackList() { print(t.index, t.type, t.name) }
            } catch { print("Error:", error.localizedDescription) }
            exit(0)
        }
        WiregramApp.main()
    }
}

struct WiregramApp: App {
    @StateObject private var model = SessionModel()

    var body: some Scene {
        WindowGroup("PT Wiregram") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Opnieuw scannen") { model.refreshNow() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("Exporteer Atmos-diagnose…") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/PT Wiregram-Atmos-diagnose.txt")
                    DispatchQueue.global().async {
                        ProToolsAX.atmosDump(to: url)
                        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                Button("Exporteer Accessibility-diagnose…") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/PT Wiregram-AX-dump.txt")
                    DispatchQueue.global().async {
                        ProToolsAX.dumpTree(to: url)
                        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
        }
    }
}
