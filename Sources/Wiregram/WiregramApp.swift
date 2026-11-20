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
        // `Wiregram --folder-diag <file>`: read-only overview of folders, hidden tracks and which
        // track names the Mix window routing reader returns.
        if let i = args.firstIndex(of: "--folder-diag"), i + 1 < args.count {
            var out = ""
            let tracks = (try? PTSLClient().trackList()) ?? []
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let routing = ProToolsAX().readRouting(forceRescan: true)
            out += "tracks: \(tracks.count), AX strips: \(routing.count)\n"
            for t in tracks {
                let parent = byID[t.parentFolderID]?.name ?? "-"
                let inAX = routing[t.name] != nil ? "AX" : (routing.keys.contains { SessionModel.normName($0) == SessionModel.normName(t.name) } ? "AX~" : "--")
                out += "\(inAX) \(t.type) open=\(t.isOpen) hidden=\(t.isHidden) explicit=\(t.isHiddenExplicitly) parent=\(parent) | \(t.name)\n"
            }
            out += "\nAX names not in track list:\n"
            let names = Set(tracks.map(\.name))
            for k in routing.keys.sorted() where !names.contains(k) { out += "  \(k)\n" }
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        // `Wiregram --transport`: prints the Pro Tools transport state (PTSL).
        if args.contains("--transport") {
            do { print(try PTSLClient().transportState()) } catch { print("error: \(error.localizedDescription)") }
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
                                            colGap: Layout.colGap,
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
        // `Wiregram --demo <png> [--tracks N] [--collapse routing|folder] [--sends all|selection|off]
        //  [--bus-names] [--no-bundle] [--full] [--dark] [--zoom z] [--select name]`:
        // render a synthetic post-production session (no Pro Tools needed).
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            MainActor.assumeIsolated {
                func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
                let n = opt("--tracks").flatMap(Int.init) ?? 60
                let (tracks, routing) = DemoSession.make(sources: n, unreadClosed: args.contains("--unread-closed"))
                let m = SessionModel()
                m.collapseMode = opt("--collapse").flatMap(SessionModel.CollapseMode.init(rawValue:)) ?? .off
                m.sendMode = opt("--sends").flatMap(SessionModel.SendMode.init(rawValue:)) ?? .all
                m.inject(tracks: tracks, routing: routing)
                if args.contains("--show-all") { m.showAllTracks = true }
                // `--bus-colors "DX Verb=#ff3060,FX Bus=#20c0a0"`: pretend I/O Setup gave these colours.
                if let bc = opt("--bus-colors") {
                    var c: [String: String] = [:]
                    for pair in bc.split(separator: ",") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { c[SessionModel.normStatic(kv[0])] = kv[1] }
                    }
                    m.setBusColors(c)
                }
                if args.contains("--no-bus-colors") { m.useIOBusColors = false }
                if opt("--levels") == "sources" { m.busLevelsFromSources = true }
                if let f = opt("--open-folder"), let t = tracks.first(where: { $0.name == f }) { m.setFolder(t.id, open: true) }
                if let f = opt("--focus") { m.focusID = m.nodes.first { $0.name == f }?.id }
                let dark = args.contains("--dark")
                let names = args.contains("--bus-names")
                let lit = opt("--select").flatMap { s in m.nodes.first { $0.name == s }?.id }.map { m.chain(of: $0) }
                let bundle = names || !args.contains("--no-bundle")
                let view = GraphContent(nodes: m.nodes, edges: m.edges,
                                        colGap: Layout.colGap + (bundle ? 50 : 0) + (names ? 90 : 0),
                                        splitPrePost: true, scale: CGFloat(opt("--zoom").flatMap(Double.init) ?? 1), lit: lit,
                                        sendMode: m.sendMode, bundle: bundle, showBusNames: names,
                                        fullColor: args.contains("--full"),
                                        onToggleCollapse: { _ in })
                    .background(Palette.canvas(dark))
                    .environment(\.colorScheme, dark ? .dark : .light)
                if dark { NSAppearance.current = NSAppearance(named: .darkAqua) }
                let r = ImageRenderer(content: view)
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: args[i + 1])) }
                print("\(m.nodes.count) blocks, \(m.edges.count) edges")
            }
            exit(0)
        }
        // `Wiregram --pio-colors [file.pio]` prints the bus colours in Pro Tools' I/O settings
        // (default: "Last Used.pio"). Read-only.
        if let i = args.firstIndex(of: "--pio-colors") {
            let url = i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : IOColors.lastUsedURL
            let data = (try? Data(contentsOf: url)) ?? Data()
            for (name, idx) in IOColors.paletteIndices(in: data).sorted(by: { $0.key < $1.key }) {
                print(idx, IOColors.palette[idx] ?? "(unknown)", name)
            }
            exit(0)
        }
        // `Wiregram --ptsl-test` prints the PTSL track list.
        if args.contains("--ptsl-test") {
            let c = PTSLClient()
            do {
                print("Session:", try c.sessionName())
                for t in try c.trackList() { print(t.index, t.type, t.color, t.name) }
            } catch { print("Error:", error.localizedDescription) }
            exit(0)
        }
        WiregramApp.main()
    }
}

struct WiregramApp: App {
    @StateObject private var model = SessionModel()
    @StateObject private var updater = Updater.shared
    @AppStorage("developerMode") private var developerMode = false

    var body: some Scene {
        WindowGroup("PT Wiregram") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // `Wiregram --demo-ui [tracks]`: run the app on a synthetic session instead of Pro Tools.
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--demo-ui") {
                        let n = i + 1 < args.count ? Int(args[i + 1]) ?? 300 : 300
                        let (t, r) = DemoSession.make(sources: n)
                        model.inject(tracks: t, routing: r)
                    } else {
                        model.start()
                        updater.launch()
                    }
                }
                .alert("Keep PT Wiregram up to date automatically?", isPresented: $updater.showPrompt) {
                    Button("Turn On") { updater.enabled = true }
                    Button("Not Now", role: .cancel) { updater.enabled = false }
                } message: {
                    Text("PT Wiregram can check GitHub once a day for a new version, download it in the background and install it when you quit the app. You can change this later in the PT Wiregram menu.")
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(manual: true) }
                Toggle("Update Automatically", isOn: Binding(get: { updater.enabled == true }, set: { updater.enabled = $0 }))
            }
            CommandGroup(after: .toolbar) {
                Button("Rescan") { model.refreshNow() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("PT Wiregram on GitHub") { DevTools.openURL(DevTools.repoURL) }
                Button("Report an Issue…") { DevTools.openURL(DevTools.repoURL + "/issues/new") }
                Divider()
                OpenSettingsButton(title: "Developer Mode…", tab: "developer")
            }
            if developerMode {
                CommandMenu("Developer") {
                    Section("Demo sessions (no Pro Tools needed)") {
                        Button("Demo Session: 24 Tracks") { model.enterDemo(sources: 24) }
                        Button("Demo Session: 60 Tracks") { model.enterDemo(sources: 60) }
                        Button("Demo Session: 300 Tracks") { model.enterDemo(sources: 300) }
                        Button("Demo Session: Closed Folder Not Read") { model.enterDemo(sources: 60, unreadClosed: true) }
                        Button("Back to Pro Tools") { model.exitDemo() }.disabled(!model.demoMode)
                    }
                    Divider()
                    Section("Diagnostics (files on the Desktop, read-only)") {
                        Button("Export Accessibility Tree…") { DevTools.export("PT Wiregram-AX-dump.txt") { ProToolsAX.dumpTree(to: $0) } }
                        Button("Export I/O Setup Diagnostics…") { DevTools.export("PT Wiregram-IO-diagnostics.txt") { ProToolsAX.probeIOSetup(to: $0) } }
                        Button("Export Atmos Diagnostics…") { DevTools.export("PT Wiregram-Atmos-diagnostics.txt") { ProToolsAX.atmosDump(to: $0) } }
                        Button("Export Folder Diagnostics…") { DevTools.export("PT Wiregram-folder-diagnostics.txt") { DevTools.folderDiagnostics(to: $0) } }
                    }
                    Divider()
                    Button("Copy Version and Status Info") { DevTools.copyStatus(model) }
                    Button("Show Settings File in Finder") { DevTools.revealSettingsFile() }
                    Button("Command-Line Options…") { DevTools.showCommandLineHelp() }
                }
            }
        }

        Settings {
            PreferencesView().environmentObject(model)
        }
    }
}

/// PT Wiregram ▸ Settings… (⌘,)
struct PreferencesView: View {
    @EnvironmentObject var model: SessionModel
    @AppStorage("settingsTab") private var selection = "general"
    @AppStorage("developerMode") private var developerMode = false

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            GraphSettings().tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }.tag("graph")
            ProToolsSettings().tabItem { Label("Pro Tools", systemImage: "waveform") }.tag("protools")
            DeveloperSettings().tabItem { Label("Developer", systemImage: "hammer") }.tag("developer")
        }
        .environmentObject(model)
        .frame(width: 540, height: 520)
    }
}

// MARK: Settings building blocks

/// A titled group of settings. Plain views in a scroll view (a grouped Form jumped to the bottom on click).
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        }
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A setting an organisation fixed with a configuration profile (e.g. Jamf) can't be changed here.
private struct Managed: ViewModifier {
    let keys: [String]
    func body(content: Content) -> some View {
        let forced = keys.contains { UserDefaults.standard.objectIsForced(forKey: $0) }
        VStack(alignment: .leading, spacing: 2) {
            content.disabled(forced)
            if forced {
                Label("Set by your organisation", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private extension View {
    func managed(_ keys: String...) -> some View { modifier(Managed(keys: keys)) }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject private var updater = Updater.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("matchAtLaunch") private var matchAtLaunch = true
    @AppStorage("askBeforeReading") private var askBeforeReading = true
    @State private var message = ""

    var body: some View {
        SettingsPage {
            SettingsGroup("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden()
                .managed("appearance")
            }
            SettingsGroup("At launch") {
                Toggle("Match Pro Tools when PT Wiregram starts", isOn: $matchAtLaunch).managed("matchAtLaunch")
                SettingsNote(matchAtLaunch
                    ? "Folders are open or closed and tracks hidden as in Pro Tools; a closed folder is one block."
                    : "PT Wiregram shows the whole session: it opens every folder and reads the tracks Pro Tools doesn't show (after one notice).")
            }
            SettingsGroup("Notices") {
                Toggle("Explain what PT Wiregram will do before it reads from Pro Tools", isOn: $askBeforeReading)
                    .managed("askBeforeReading")
                Button("Show Notices Again") { model.showReadNoticesAgain(); message = "Notices will be shown again." }
                SettingsNote("Brings back the notice you switched off with \u{201C}Don't ask again until PT Wiregram quits\u{201D}.")
            }
            SettingsGroup("Updates") {
                Toggle("Update automatically", isOn: Binding(get: { updater.enabled == true }, set: { updater.enabled = $0 }))
                    .managed("autoUpdate")
                HStack {
                    Button("Check Now") { updater.check(manual: true) }
                    Text("Version \(Updater.currentVersion ?? "–")").font(.caption).foregroundStyle(.secondary)
                }
                SettingsNote("When on, PT Wiregram checks GitHub once a day, downloads a new version in the background and installs it when you quit.")
            }
            SettingsGroup("Settings file") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                }
                SettingsNote("Saves all PT Wiregram settings to a file you can share, e.g. to set up every Mac in a studio the same way. Session data (groups, hidden tracks, block positions) isn't included.")
                if !message.isEmpty { Text(message).font(.caption) }
            }
        }
    }

    private func exportSettings() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "PT Wiregram Settings.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try model.exportSettings(to: url); message = "Settings exported." }
        catch { message = "Couldn't export: \(error.localizedDescription)" }
    }

    private func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { let n = try model.importSettings(from: url); message = "\(n) settings imported." }
        catch { message = "Couldn't import: \(error.localizedDescription)" }
    }
}

// MARK: Graph

struct GraphSettings: View {
    @EnvironmentObject var model: SessionModel
    @AppStorage("trackFill") private var trackFill = "stripe"
    @AppStorage("defaultZoom") private var defaultZoom = 1.0

    var body: some View {
        SettingsPage {
            SettingsGroup("Line colours") {
                Picker("Lines use", selection: $model.useIOBusColors) {
                    Text("Track colours").tag(false)
                    Text("Bus colours from I/O Setup").tag(true)
                }
                .pickerStyle(.radioGroup).managed("useIOBusColors")
                if model.useIOBusColors {
                    Picker("Buses without a colour", selection: $model.greyUncolouredBuses) {
                        Text("Colour of their tracks").tag(false)
                        Text("Neutral grey").tag(true)
                    }
                    .managed("greyUncolouredBuses")
                    SettingsNote("A bus with a colour in Pro Tools' I/O Setup draws its lines in that colour. Pro Tools saves I/O Setup changes when you click OK. "
                        + (model.busColors.isEmpty ? "No coloured buses found yet."
                           : "\(model.busColors.count) coloured bus\(model.busColors.count == 1 ? "" : "es") found."))
                } else {
                    SettingsNote("Lines have the colour of the track they come from, as in Pro Tools.")
                }
                Toggle("Mark pre-fader sends with blue dots (as in Pro Tools)", isOn: $model.splitPrePost).managed("splitPrePost")
            }
            SettingsGroup("Blocks") {
                Picker("Track colour", selection: $trackFill) {
                    Text("Stripe").tag("stripe")
                    Text("Whole block").tag("full")
                }
                .pickerStyle(.segmented).managed("trackFill")
                LabeledContent("Zoom when opening") {
                    HStack {
                        Slider(value: $defaultZoom, in: 0.5...2, step: 0.25)
                        Text("\(Int(defaultZoom * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .managed("defaultZoom")
            }
            SettingsGroup("Bus columns") {
                Picker("Place buses", selection: $model.busLevelsFromSources) {
                    Text("By distance to the outputs").tag(false)
                    Text("By distance from the sources").tag(true)
                }
                .pickerStyle(.radioGroup).managed("busLevelsFromSources")
                SettingsNote(model.busLevelsFromSources
                    ? "A bus fed by tracks is always in the first bus column; each bus after it is one column further."
                    : "Buses that do the same job line up, e.g. all stems in one column. A bus that goes straight to an output moves to the last bus column.")
            }
        }
    }
}

// MARK: Pro Tools

struct ProToolsSettings: View {
    @EnvironmentObject var model: SessionModel
    @AppStorage("stopPlaybackBeforeReading") private var stopPlayback = true
    @AppStorage("readHiddenOnOpen") private var readHiddenOnOpen = false
    /// Slider stops, in seconds: 1 s … 30 min.
    static let stops: [Double] = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800]

    static func label(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) s" }
        let m = Int(s / 60)
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    var body: some View {
        let stopIndex = Binding<Double>(
            get: { Double(Self.stops.firstIndex { $0 >= model.refreshSeconds } ?? Self.stops.count - 1) },
            set: { model.refreshSeconds = Self.stops[Int($0.rounded())] })
        SettingsPage {
            SettingsGroup("Refresh") {
                Toggle("Only when I click Rescan (⌘R)", isOn: $model.refreshManual).managed("refreshManual")
                LabeledContent("Every") {
                    HStack {
                        Slider(value: stopIndex, in: 0...Double(Self.stops.count - 1), step: 1)
                        Text(Self.label(model.refreshSeconds)).monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                }
                .disabled(model.refreshManual)
                .managed("refreshSeconds")
                SettingsNote("Each refresh asks Pro Tools for its track list and reads the Mix window. In large sessions that costs Pro Tools some CPU, which you may notice while playing back or recording. A longer interval, or refreshing only when you click Rescan, keeps Pro Tools lighter; changes in the session then show up later. Reading groups, hidden tracks or the I/O Setup always refreshes right away.")
            }
            SettingsGroup("Reading") {
                Toggle("Stop playback before reading", isOn: $stopPlayback).managed("stopPlaybackBeforeReading")
                SettingsNote("Reading is more reliable when Pro Tools isn't playing. A running recording is never stopped: PT Wiregram waits until it has ended.")
                Toggle("Read hidden tracks when a session opens", isOn: $readHiddenOnOpen).managed("readHiddenOnOpen")
                SettingsNote("Otherwise hidden tracks are read when you ask for it (Read ▸ Hidden Tracks).")
            }
        }
    }
}

// MARK: Developer

struct DeveloperSettings: View {
    @EnvironmentObject var model: SessionModel
    @AppStorage("developerMode") private var developerMode = false

    var body: some View {
        SettingsPage {
            SettingsGroup("Developer mode") {
                Toggle("Show the Developer menu", isOn: $developerMode)
                SettingsNote("For people who help develop PT Wiregram or report a problem. The Developer menu has demo sessions that work without Pro Tools, diagnostic exports that show what PT Wiregram reads from Pro Tools, and shortcuts to the settings file and the command-line options. Nothing in it changes your Pro Tools session.")
            }
            if developerMode {
                SettingsGroup("Demo sessions") {
                    HStack {
                        Button("24 Tracks") { model.enterDemo(sources: 24) }
                        Button("60 Tracks") { model.enterDemo(sources: 60) }
                        Button("300 Tracks") { model.enterDemo(sources: 300) }
                        Button("Back to Pro Tools") { model.exitDemo() }.disabled(!model.demoMode)
                    }
                    SettingsNote("A made-up post-production session (dialogue, effects, backgrounds and music with buses, stems and a closed folder), so you can try PT Wiregram and test changes without Pro Tools.")
                }
                SettingsGroup("Diagnostics") {
                    Button("Export Accessibility Tree…") { DevTools.export("PT Wiregram-AX-dump.txt") { ProToolsAX.dumpTree(to: $0) } }
                    Button("Export I/O Setup Diagnostics…") { DevTools.export("PT Wiregram-IO-diagnostics.txt") { ProToolsAX.probeIOSetup(to: $0) } }
                    Button("Export Folder Diagnostics…") { DevTools.export("PT Wiregram-folder-diagnostics.txt") { DevTools.folderDiagnostics(to: $0) } }
                    SettingsNote("Writes a text file to the Desktop with what PT Wiregram sees in Pro Tools. Useful to attach to a bug report. For the I/O Setup export, open Setup ▸ I/O in Pro Tools first.")
                }
                SettingsGroup("Tools") {
                    HStack {
                        Button("Copy Version and Status Info") { DevTools.copyStatus(model) }
                        Button("Show Settings File") { DevTools.revealSettingsFile() }
                    }
                    HStack {
                        Button("Command-Line Options…") { DevTools.showCommandLineHelp() }
                        Button("Source Code on GitHub") { DevTools.openURL(DevTools.repoURL) }
                    }
                }
            }
        }
    }
}

/// Helpers behind the Developer menu and the Developer settings.
@MainActor
enum DevTools {
    static let repoURL = "https://github.com/" + Updater.repo

    static func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    /// Runs a (read-only) diagnostic in the background and shows the file in Finder.
    static func export(_ name: String, _ work: @escaping (URL) -> Void) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/" + name)
        DispatchQueue.global().async {
            work(url)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    nonisolated static func folderDiagnostics(to url: URL) {
        var out = ""
        let tracks = (try? PTSLClient().trackList()) ?? []
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let routing = ProToolsAX().readRouting(forceRescan: true)
        out += "tracks: \(tracks.count), AX strips: \(routing.count)\n"
        for t in tracks {
            let parent = byID[t.parentFolderID]?.name ?? "-"
            let inAX = routing[t.name] != nil ? "AX" : "--"
            out += "\(inAX) \(t.type) open=\(t.isOpen) hidden=\(t.isHidden) explicit=\(t.isHiddenExplicitly) parent=\(parent) | \(t.name)\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func copyStatus(_ m: SessionModel) {
        let pt = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.avid.ProTools" }
        let ptVersion = pt?.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "not running"
        let text = """
        PT Wiregram \(Updater.currentVersion ?? "dev build")
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Pro Tools \(ptVersion)
        PTSL: \(m.ptslStatus)
        Accessibility: \(m.axTrusted ? "allowed" : "not allowed")
        Session: \(m.demoMode ? "demo" : (m.sessionName.isEmpty ? "none" : "open")), \(m.tracks.count) tracks, \(m.nodes.count) blocks, \(m.edges.count) lines
        Coloured buses: \(m.busColors.count)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealSettingsFile() {
        let id = Bundle.main.bundleIdentifier ?? "nl.wiregram.protools"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(id).plist")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func showCommandLineHelp() {
        let a = NSAlert()
        a.messageText = "Command-line options"
        a.informativeText = """
        Run the app binary from Terminal:
        "PT Wiregram.app/Contents/MacOS/Wiregram" <option>

        --demo out.png [--tracks N] [--collapse routing|folder] [--zoom z] [--dark]
            Render the demo session to a PNG (no Pro Tools needed).
        --demo-ui [N]   Run the app on the demo session.
        --ptsl-test     Print the Pro Tools track list (PTSL).
        --transport     Print the transport state.
        --pio-colors [file.pio]   Print the bus colours in Pro Tools' I/O settings.
        --dump-ax file.txt        Write Pro Tools' accessibility tree.
        --folder-diag file.txt    Folders, hidden tracks and what the Mix window shows.

        Reading from Terminal needs Accessibility permission for Terminal.
        """
        a.addButton(withTitle: "Copy")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.informativeText, forType: .string)
        }
    }
}
