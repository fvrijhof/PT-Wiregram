import Cocoa
import ApplicationServices

/// Routing for one track strip as read from Pro Tools' Mix (or Edit) window via Accessibility.
struct AXRouting: Equatable, Codable {
    var input: String?
    var outputs: [String] = []
    var outputParents: [String: String] = [:] // sub-path -> main output path ("7.1.4 out" -> "Output")
    var sends: [String: String] = [:] // "A" -> destination path
    var sendStates: [String: String] = [:] // "A" -> "muted", "inactive", "pre is active", ...
    var inserts: [String] = []              // plug-in names, e.g. "FabFilter Pro-Q 3 (bypassed)"
    var vcaGroup: String?                    // on a VCA strip: the group it controls
    // Dolby Atmos: a track can be assigned to a bed (its bus outputs) and an object at once;
    // the Bus/Object toggle decides which one actually receives the signal.
    var objectPath: String?                  // e.g. "Object 11-12"
    var objectActive: Bool?                  // true = object selected, false = bus/bed selected
    var atmosGroup: String?
}

/// Reads I/O + send routing from Pro Tools' UI through the macOS Accessibility API.
/// PTSL (2024.10) exposes no routing commands, so this is the only live source.
final class ProToolsAX {
    private struct StripRefs {
        var input: AXUIElement?
        var outputs: [AXUIElement] = []
        var sends: [(String, AXUIElement)] = []
        var sendStates: [(String, AXUIElement)] = []
        var inserts: [(String, AXUIElement)] = []       // slot -> "Insert Assignment X"
        var insertStates: [String: AXUIElement] = [:]   // slot -> "Insert selector X"
        var vcaGroup: AXUIElement?
        var objectOut: AXUIElement?
        var busObjectToggle: AXUIElement?
        var atmosGroup: AXUIElement?
    }

    private var cache: [String: StripRefs] = [:]   // strip name -> element refs
    private var cachedPID: pid_t = 0
    private var lastFullScan = Date.distantPast
    private(set) var windowUsed: String = ""

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var proToolsPID: pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.avid.ProTools" || $0.localizedName == "Pro Tools"
        }?.processIdentifier
    }

    /// Returns routing keyed by the strip's track name.
    func readRouting(forceRescan: Bool = false) -> [String: AXRouting] {
        guard let pid = Self.proToolsPID else { cache = [:]; return [:] }
        if pid != cachedPID || forceRescan || cache.isEmpty || Date().timeIntervalSince(lastFullScan) > 6 {
            rescan(pid: pid)
        }
        var result: [String: AXRouting] = [:]
        var stale = false
        for (name, refs) in cache {
            var r = AXRouting()
            if let i = refs.input {
                guard let v = Self.pathValue(i) else { stale = true; continue }
                r.input = v
            }
            for el in refs.outputs {
                for (name, parent) in Self.outputPaths(el) {
                    if !r.outputs.contains(name) { r.outputs.append(name) }
                    if let parent { r.outputParents[name] = parent }
                }
            }
            for (slot, el) in refs.sends {
                if let v = Self.pathValue(el), !v.isEmpty { r.sends[slot] = v }
            }
            for (slot, el) in refs.sendStates where r.sends[slot] != nil {
                let st = (Self.attr(el, kAXValueAttribute) as? String) ?? ""
                if !st.isEmpty { r.sendStates[slot] = st }
            }
            for (slot, el) in refs.inserts.sorted(by: { $0.0 < $1.0 }) {
                let name = (Self.attr(el, kAXValueAttribute) as? String) ?? ""
                if name.isEmpty || name.lowercased().hasPrefix("unassigned") { continue }
                let st = refs.insertStates[slot].flatMap { Self.attr($0, kAXValueAttribute) as? String } ?? ""
                r.inserts.append(st.isEmpty ? name : "\(name) (\(st))")
            }
            if let o = refs.objectOut, let v = Self.pathValue(o), !v.isEmpty {
                r.objectPath = v
                r.outputs.removeAll { SessionModel.normStatic($0) == SessionModel.normStatic(v) }
                r.outputParents[v] = nil
                if let t = refs.busObjectToggle, let tv = (Self.attr(t, kAXValueAttribute) as? String)?.lowercased() {
                    if tv.contains("object selected") { r.objectActive = true }
                    else if tv.contains("bus selected") { r.objectActive = false }
                }
            }
            if let g = refs.atmosGroup, let v = Self.attr(g, kAXValueAttribute) as? String,
               !v.isEmpty, !["none", "n/a"].contains(v.lowercased()) { r.atmosGroup = v }
            if let g = refs.vcaGroup, let v = Self.attr(g, kAXValueAttribute) as? String, !v.isEmpty,
               v.lowercased() != "none", v.lowercased() != "no group" {
                r.vcaGroup = v
            }
            result[name] = r
        }
        if stale { lastFullScan = .distantPast }
        return result
    }

    // MARK: Scan

    private func rescan(pid: pid_t) {
        cachedPID = pid
        lastFullScan = Date()
        cache = [:]
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        let windows = (Self.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        // Prefer the Mix window; fall back to the Edit window (I/O + Sends views).
        let ranked = windows.sorted { Self.windowRank($0) < Self.windowRank($1) }
        for w in ranked {
            var found: [String: StripRefs] = [:]
            collect(w, stripName: nil, depth: 0, into: &found)
            if !found.isEmpty {
                cache = found
                windowUsed = (Self.attr(w, kAXTitleAttribute) as? String) ?? ""
                return
            }
        }
        windowUsed = ""
    }

    private static func windowRank(_ w: AXUIElement) -> Int {
        let t = (attr(w, kAXTitleAttribute) as? String) ?? ""
        if t.hasPrefix("Mix") { return 0 }
        if t.hasPrefix("Edit") { return 1 }
        return 2
    }

    private func collect(_ el: AXUIElement, stripName: String?, depth: Int, into found: inout [String: StripRefs]) {
        if depth > 12 { return }
        let role = (Self.attr(el, kAXRoleAttribute) as? String) ?? ""
        let title = (Self.attr(el, kAXTitleAttribute) as? String) ?? ""
        var strip = stripName

        if role == kAXGroupRole, let n = Self.trackName(fromStripTitle: title) {
            strip = n
        }

        if let s = strip, role == kAXButtonRole || role == kAXPopUpButtonRole {
            let l = title.lowercased()
            if l.hasPrefix("audio input path selector") {
                found[s, default: StripRefs()].input = el
                return
            } else if l.hasPrefix("audio output path selector") {
                found[s, default: StripRefs()].outputs.append(el)
                return
            } else if l.hasPrefix("send assignment ") {
                let slot = String(title.split(separator: "\n").first?.split(separator: " ").last ?? "?")
                found[s, default: StripRefs()].sends.append((slot, el))
                return
            } else if l.hasPrefix("send selector ") {
                let slot = String(title.split(separator: " ").last ?? "?")
                found[s, default: StripRefs()].sendStates.append((slot, el))
                return
            } else if l.hasPrefix("insert assignment ") {
                let slot = String(title.split(separator: "\n").first?.split(separator: " ").last ?? "?")
                found[s, default: StripRefs()].inserts.append((slot, el))
                return
            } else if l.hasPrefix("insert selector ") {
                let slot = String(title.split(separator: " ").last ?? "?")
                found[s, default: StripRefs()].insertStates[slot] = el
                return
            } else if l.hasPrefix("object output path selector") {
                found[s, default: StripRefs()].objectOut = el
                return
            } else if l.hasPrefix("bus/object toggle") {
                found[s, default: StripRefs()].busObjectToggle = el
                return
            } else if l.hasPrefix("dolby atmos group selector") {
                found[s, default: StripRefs()].atmosGroup = el
                return
            } else if l.hasPrefix("group assignment selector") {
                found[s, default: StripRefs()].vcaGroup = el
                return
            }
        }

        guard let kids = Self.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids { collect(k, stripName: strip, depth: depth + 1, into: &found) }
    }

    /// Pro Tools strip groups are titled like `Kick - Audio Track ` / `FX - Aux Track `.
    static func trackName(fromStripTitle t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard let r = s.range(of: " - ", options: .backwards) else { return nil }
        let kind = s[r.upperBound...]
        guard kind.hasSuffix("Track") || kind.hasSuffix("Fader") else { return nil }
        let name = String(s[..<r.lowerBound])
        return name.isEmpty ? nil : name
    }

    static func pathValue(_ el: AXUIElement) -> String? {
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
        if err == .invalidUIElement { return nil }
        var s = (v as? String) ?? ""
        if s.isEmpty { s = (attr(el, kAXTitleAttribute) as? String) ?? "" }
        let lower = s.lowercased()
        if lower.contains("selector") || lower.hasPrefix("send assignment") { return "" } // label only
        if ["no input", "no output", "none", "no object"].contains(lower) || lower.hasPrefix("unassigned") { return "" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// All output assignments of a strip. The selector's title lists every assigned path on
    /// its own line, e.g. "Audio Output Path selector\nPM 5.1 (5.1)\n7.1.4 out (7.1.4) -> Output";
    /// its value only shows the first one (prefixed with "+" when there are more).
    static func outputPaths(_ el: AXUIElement) -> [(String, String?)] {
        let title = (attr(el, kAXTitleAttribute) as? String) ?? ""
        var result: [(String, String?)] = []
        for raw in title.components(separatedBy: .newlines).dropFirst() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let r = line.range(of: " - track inactive") { line = String(line[..<r.lowerBound]) }
            var parent: String?
            if let r = line.range(of: " -> ", options: .backwards) {
                var p = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if p.hasSuffix(")"), let o = p.range(of: " (", options: .backwards) { p = String(p[..<o.lowerBound]) }
                parent = p
                line = String(line[..<r.lowerBound])
            }
            if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
                line = String(line[..<open.lowerBound])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty || lower == "no output" || lower == "none" { continue }
            result.append((line, parent))
        }
        if result.isEmpty, let v = pathValue(el), !v.isEmpty { result.append((v, nil)) }
        return result
    }

    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    // MARK: I/O Setup

    /// Reads main paths from the I/O Setup window (only while it is open; read-only).
    /// Returns [] otherwise, so the model keeps what it learned earlier.
    static func readIOSetup() -> [String: IOPathInfo] {
        guard let pid = proToolsPID else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let w = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
            .first(where: { (attr($0, kAXTitleAttribute) as? String) == "I/O Setup" }) else { return [:] }
        let kids = (attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        // Active tab, e.g. "Output 2 of 7" with value 1. Bus/Insert tabs aren't hardware.
        let tab = kids.first { (attr($0, kAXRoleAttribute) as? String) == "AXRadioButton" && "\(attr($0, kAXValueAttribute) ?? 0 as AnyObject)" == "1" }
            .flatMap { attr($0, kAXTitleAttribute) as? String }?.components(separatedBy: " ").first ?? ""
        guard tab == "Input" || tab == "Output" || tab == "Dolby" else { return [:] }
        let direction = tab == "Dolby" ? "Atmos" : tab
        let tables = kids.filter { (attr($0, kAXRoleAttribute) as? String) == "AXTable" }
        let setup = tables.first { ((attr($0, kAXTitleAttribute) as? String) ?? "").hasSuffix("Setup") }
        var device = tables.compactMap { attr($0, kAXTitleAttribute) as? String }
            .first { !$0.hasSuffix("Setup") && $0 != "TextGridView" && !$0.isEmpty } ?? ""
        if direction == "Atmos" { // renderer choice, e.g. "Internal Renderer"
            device = kids.compactMap { (attr($0, kAXRoleAttribute) as? String) == "AXPopUpButton" ? attr($0, kAXValueAttribute) as? String : nil }
                .first { $0.localizedCaseInsensitiveContains("renderer") } ?? "Dolby Atmos Renderer"
        }
        guard let setup else { return [:] }
        var out: [String: IOPathInfo] = [:]
        for row in (attr(setup, kAXRowsAttribute) as? [AXUIElement]) ?? [] {
            var name = "", format = "", active = true
            for cell in (attr(row, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for k in (attr(cell, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let role = (attr(k, kAXRoleAttribute) as? String) ?? ""
                    let v = (attr(k, kAXValueAttribute) as? String) ?? ""
                    if role == "AXTextField" {
                        if v.hasPrefix("Active. ") { name = String(v.dropFirst(8)) }
                        else if v.hasPrefix("Inactive. ") { name = String(v.dropFirst(10)); active = false }
                        else { name = v }
                    } else if role == "AXMenuButton" {
                        format = v
                    }
                }
            }
            if !name.isEmpty {
                out[direction.lowercased() + ":" + SessionModel.normStatic(name)] = IOPathInfo(name: name, direction: direction, format: format, device: device,
                                                               channels: "", active: active)
            }
        }
        return out
    }

    /// Opens Setup ▸ I/O (if it isn't open), reads the Input and Output tabs, and closes the
    /// window again with Cancel so nothing is changed. Returns what was read.
    static func readIOViaDialog() throws -> [String: IOPathInfo] {
        guard let pid = proToolsPID else { throw PTSLClient.PTSLError(message: "Pro Tools draait niet") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        func ioWindow() -> AXUIElement? {
            ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first { (attr($0, kAXTitleAttribute) as? String) == "I/O Setup" }
        }
        var openedByUs = false
        if ioWindow() == nil {
            guard let item = menuItem(app, menu: "Setup", itemPrefix: "I/O") else {
                throw PTSLClient.PTSLError(message: "Menu Setup ▸ I/O… niet gevonden")
            }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            openedByUs = true
            for _ in 0..<30 where ioWindow() == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let w = ioWindow() else { throw PTSLClient.PTSLError(message: "I/O Setup-venster ging niet open") }
        let kids = (attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        func tab(_ prefix: String) -> AXUIElement? {
            kids.first { (attr($0, kAXRoleAttribute) as? String) == "AXRadioButton" && ((attr($0, kAXTitleAttribute) as? String) ?? "").hasPrefix(prefix + " ") }
        }
        let originalTab = kids.first { (attr($0, kAXRoleAttribute) as? String) == "AXRadioButton" && "\(attr($0, kAXValueAttribute) ?? 0 as AnyObject)" == "1" }
        var result: [String: IOPathInfo] = [:]
        for name in ["Input", "Output", "Dolby Atmos"] {
            if let t = tab(name) {
                AXUIElementPerformAction(t, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.4)
            }
            result.merge(readIOSetup()) { _, n in n }
        }
        if openedByUs {
            if let cancel = kids.first(where: { (attr($0, kAXRoleAttribute) as? String) == "AXButton" && (attr($0, kAXTitleAttribute) as? String) == "Cancel" }) {
                AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            }
        } else if let originalTab {
            AXUIElementPerformAction(originalTab, kAXPressAction as CFString)
        }
        return result
    }

    static func menuItem(_ app: AXUIElement, menu: String, itemPrefix: String) -> AXUIElement? {
        guard let bar = attr(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
        for top in (attr(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attr(top, kAXTitleAttribute) as? String) == menu {
            for m in (attr(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (attr(m, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    if ((attr(item, kAXTitleAttribute) as? String) ?? "").hasPrefix(itemPrefix) { return item }
                }
            }
        }
        return nil
    }

    /// Hidden tracks have no strip in the Mix window. Temporarily unhide the explicitly hidden
    /// ones through PTSL, read their routing, and hide them again.
    /// `unhide` = tracks/folders hidden explicitly by the user (only these are toggled and
    /// re-hidden); `names` = the hidden tracks whose routing we want (incl. tracks hidden
    /// implicitly because their folder is hidden).
    /// `openFolders` = closed folders containing hidden tracks; opened briefly, closed again.
    static func readHiddenRouting(ptsl: PTSLClient, names: [String], unhide: [String]? = nil,
                                  openFolders: [String] = []) throws -> [String: AXRouting] {
        guard !names.isEmpty else { return [:] }
        let toggle = unhide ?? names
        try ptsl.setHidden(toggle, hidden: false)
        defer { try? ptsl.setHidden(toggle, hidden: true) }      // runs last
        try ptsl.setOpen(openFolders, open: true)
        defer { try? ptsl.setOpen(openFolders, open: false) }    // runs first
        Thread.sleep(forTimeInterval: 0.8)
        let ax = ProToolsAX()
        var all = ax.readRouting(forceRescan: true)
        if names.contains(where: { all[$0] == nil }) { // give Pro Tools a moment more
            Thread.sleep(forTimeInterval: 1.0)
            all = ax.readRouting(forceRescan: true)
        }
        let wanted = Set(names)
        return all.filter { wanted.contains($0.key) }
    }

    // MARK: Groups

    struct PTGroup: Equatable, Hashable, Codable {
        let id: String        // "a"
        let name: String      // "DX group"
        let vca: String?      // "DX VCA"
        var members: [String]
    }

    /// Pro Tools does not expose group membership directly. Each row of the Mix window's
    /// Group List does show a read-only indicator ("Track selection contains no member of
    /// group" / "partially contains group" / ...). We select one track at a time through the
    /// official PTSL API, read those indicators, and restore the original selection.
    /// Nothing is clicked.
    static func readGroups(ptsl: PTSLClient, trackNames: [String], progress: (Int, Int) -> Void = { _, _ in }) throws -> [PTGroup] {
        guard let pid = proToolsPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var rows: [(title: String, indicator: AXUIElement)] = []
        for w in windows.sorted(by: { windowRank($0) < windowRank($1) }) {
            guard let table = findGroupList(w, depth: 0) else { continue }
            for row in (attr(table, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                var title: String?, indicator: AXUIElement?
                for cell in (attr(row, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    for b in (attr(cell, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                        let t = (attr(b, kAXTitleAttribute) as? String) ?? ""
                        if t.hasPrefix("Track selection") { indicator = b }
                        else if t.contains(" - ") { title = t }
                    }
                }
                if let title, let indicator, !title.hasPrefix("! - ") { rows.append((title, indicator)) }
            }
            if !rows.isEmpty { break }
        }
        guard !rows.isEmpty else {
            throw PTSLClient.PTSLError(message: "Geen Group List gevonden. Open het Mix-venster met de Groups-lijst zichtbaar.")
        }

        let original = try ptsl.selectedTrackNames()
        var restored = false
        defer { if !restored { try? ptsl.selectTracks(original) } }

        var members: [[String]] = Array(repeating: [], count: rows.count)
        for (i, name) in trackNames.enumerated() {
            progress(i, trackNames.count)
            guard (try? ptsl.selectTracks([name])) != nil else { continue }
            Thread.sleep(forTimeInterval: 0.06)
            // If an active group expanded the selection, only trust groups that are fully selected.
            let selected = (try? ptsl.selectedTrackNames()) ?? [name]
            let expanded = selected.count > 1
            for (gi, r) in rows.enumerated() {
                let v = ((attr(r.indicator, kAXValueAttribute) as? String) ?? (attr(r.indicator, kAXTitleAttribute) as? String) ?? "").lowercased()
                if v.contains("no member") || v.isEmpty { continue }
                if expanded && v.contains("partially") { continue }
                members[gi].append(name)
            }
        }
        try ptsl.selectTracks(original)
        restored = true
        return rows.enumerated().map { parseGroup($1.title, members: members[$0]) }
    }

    static func parseGroup(_ t: String, members: [String]) -> PTGroup {
        let parts = t.components(separatedBy: " - ")
        let id = parts.first ?? "?"
        var rest = parts.dropFirst().joined(separator: " - ")
        var vca: String?
        if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
            vca = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open.lowerBound])
        }
        return PTGroup(id: id, name: rest, vca: vca, members: members)
    }

    private static func findGroupList(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 4 { return nil }
        if (attr(e, kAXTitleAttribute) as? String) == "Group List" { return e }
        for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let f = findGroupList(k, depth: depth + 1) { return f }
        }
        return nil
    }

    // MARK: Diagnostics

    /// Dumps every attribute of the I/O Setup window's tables (to learn how assignments are exposed).
    static func probeIOSetup(to url: URL) {
        var out = ""
        guard let pid = proToolsPID else { return }
        let app = AXUIElementCreateApplication(pid)
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, kAXTitleAttribute) as? String) == "I/O Setup" {
            for t in (attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attr(t, kAXRoleAttribute) as? String) == "AXTable" {
                out += "TABLE \((attr(t, kAXTitleAttribute) as? String) ?? "")\n"
                out += allAttrs(t, indent: "  ")
                let rows = (attr(t, kAXRowsAttribute) as? [AXUIElement]) ?? []
                for (ri, row) in rows.prefix(4).enumerated() {
                    out += "  ROW \(ri)\n" + allAttrs(row, indent: "    ")
                    for (ci, cell) in ((attr(row, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(6).enumerated() {
                        out += "    CELL \(ci)\n" + allAttrs(cell, indent: "      ")
                        for k in (attr(cell, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { out += "      CHILD\n" + allAttrs(k, indent: "        ") }
                    }
                }
            }
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func allAttrs(_ e: AXUIElement, indent: String) -> String {
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        var out = ""
        for n in (names as? [String]) ?? [] where n != "AXChildren" && n != "AXParent" && n != "AXRows" && n != "AXColumns" && n != "AXVisibleRows" && n != "AXVisibleColumns" && n != "AXTopLevelUIElement" && n != "AXWindow" {
            let v = attr(e, n).map { "\($0)" } ?? "nil"
            out += "\(indent)\(n) = \(v.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))\n"
        }
        var acts: CFArray?
        AXUIElementCopyActionNames(e, &acts)
        out += "\(indent)actions = \((acts as? [String]) ?? [])\n"
        return out
    }

    /// Writes the Pro Tools accessibility tree to a text file (for debugging the parser).
    /// Collects everything Atmos-related Pro Tools (and an external Dolby Atmos Renderer)
    /// exposes, so the Atmos layer can be built on real data. Read-only, except that the
    /// I/O Setup window is opened on its "Dolby Atmos" tab and closed again with Cancel.
    static func atmosDump(to url: URL) {
        var out = "PT Wiregram Atmos-diagnose · \(Date())\ntrusted=\(isTrusted)\n"
        guard let pid = proToolsPID else {
            try? (out + "Pro Tools draait niet\n").write(to: url, atomically: true, encoding: .utf8); return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []

        out += "\n== Pro Tools-vensters\n"
        for w in windows { out += "  \((attr(w, kAXTitleAttribute) as? String) ?? "?")\n" }

        out += "\n== Menu-items met Atmos/Renderer/Object/Bed\n"
        if let bar = attr(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) {
            func walk(_ e: AXUIElement, _ path: String, _ d: Int) {
                if d > 4 { return }
                for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let t = (attr(k, kAXTitleAttribute) as? String) ?? ""
                    let p = t.isEmpty ? path : path + " ▸ " + t
                    if t.range(of: "atmos|renderer|object|bed", options: [.regularExpression, .caseInsensitive]) != nil { out += "  \(p)\n" }
                    walk(k, p, d + 1)
                }
            }
            walk(bar, "", 0)
        }

        out += "\n== Mix-strips: I/O-sectie en alles met Atmos/Object/Bed\n"
        if let mix = windows.first(where: { ((attr($0, kAXTitleAttribute) as? String) ?? "").hasPrefix("Mix") }) {
            for strip in (attr(mix, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                let st = (attr(strip, kAXTitleAttribute) as? String) ?? ""
                guard trackName(fromStripTitle: st) != nil else { continue }
                var part = ""
                for k in (attr(strip, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let t = (attr(k, kAXTitleAttribute) as? String) ?? ""
                    let d = (attr(k, kAXDescriptionAttribute) as? String) ?? ""
                    if t == "Audio IO" || "\(t) \(d)".range(of: "atmos|object|bed|panner|output", options: [.regularExpression, .caseInsensitive]) != nil {
                        dump(k, 2, 6, &part)
                    }
                }
                out += "  STRIP \(st)\n" + part
            }
        } else { out += "  (Mix-venster niet open)\n" }

        out += "\n== I/O Setup ▸ Dolby Atmos-tab\n"
        func ioWindow() -> AXUIElement? {
            ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first { (attr($0, kAXTitleAttribute) as? String) == "I/O Setup" }
        }
        var opened = false
        if ioWindow() == nil, let item = menuItem(app, menu: "Setup", itemPrefix: "I/O") {
            AXUIElementPerformAction(item, kAXPressAction as CFString); opened = true
            for _ in 0..<30 where ioWindow() == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        if let w = ioWindow() {
            let kids = (attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let radios = kids.filter { (attr($0, kAXRoleAttribute) as? String) == "AXRadioButton" }
            let original = radios.first { "\(attr($0, kAXValueAttribute) ?? 0 as AnyObject)" == "1" }
            if let tab = radios.first(where: { ((attr($0, kAXTitleAttribute) as? String) ?? "").hasPrefix("Dolby Atmos") }) {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.6)
                dump(w, 1, 10, &out)
            } else { out += "  (geen Dolby Atmos-tab gevonden)\n" }
            if opened {
                if let cancel = kids.first(where: { (attr($0, kAXTitleAttribute) as? String) == "Cancel" }) {
                    AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                }
            } else if let original { AXUIElementPerformAction(original, kAXPressAction as CFString) }
        } else { out += "  (I/O Setup kon niet geopend worden)\n" }

        out += "\n== Pro Tools-vensters met Atmos/Renderer in de titel\n"
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            let t = (attr(w, kAXTitleAttribute) as? String) ?? ""
            if t.range(of: "atmos|renderer", options: [.regularExpression, .caseInsensitive]) != nil { dump(w, 1, 10, &out) }
        }

        out += "\n== Externe renderer-apps\n"
        let renderers = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName ?? "").range(of: "atmos|renderer", options: [.regularExpression, .caseInsensitive]) != nil
        }
        if renderers.isEmpty { out += "  (geen draaiende Dolby Atmos Renderer-app)\n" }
        for r in renderers {
            out += "  APP \(r.localizedName ?? "?") (\(r.bundleIdentifier ?? "?"))\n"
            let ra = AXUIElementCreateApplication(r.processIdentifier)
            AXUIElementSetMessagingTimeout(ra, 3.0)
            for w in (attr(ra, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { dump(w, 2, 10, &out) }
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func dumpTree(to url: URL, maxDepth: Int = 9) {
        var out = "trusted=\(isTrusted)\n"
        if let pid = proToolsPID {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 3.0)
            for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                dump(w, 0, maxDepth, &out)
            }
        } else {
            out += "Pro Tools draait niet\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func dump(_ e: AXUIElement, _ d: Int, _ maxD: Int, _ out: inout String) {
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
        let val = attr(e, kAXValueAttribute).map { "\($0)" } ?? ""
        out += String(repeating: "  ", count: d) + "\(role) t=\"\(title)\" d=\"\(desc)\" v=\"\(val.prefix(80))\"\n"
        if d >= maxD { return }
        for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { dump(k, d + 1, maxD, &out) }
    }
}
