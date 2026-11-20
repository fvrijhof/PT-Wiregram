import Foundation

/// A synthetic post-production session for testing the graph without Pro Tools
/// (used by `Wiregram --demo`).
enum DemoSession {
    static func make(sources: Int, unreadClosed: Bool = false) -> ([PTTrack], [String: AXRouting]) {
        var tracks: [PTTrack] = []
        var routing: [String: AXRouting] = [:]
        var index = 0
        func add(_ name: String, _ type: String, color: String, folder: String = "", format: String = "TF_Mono",
                 open: Bool = true, hiddenByFolder: Bool = false) -> String {
            index += 1
            let id = "id\(index)"
            tracks.append(PTTrack(json: ["id": id, "name": name, "type": type, "index": index, "color": color,
                                         "format": format, "parent_folder_id": folder,
                                         "track_attributes": ["is_inactive": "None", "is_open": open,
                                                              "is_hidden": hiddenByFolder ? "SetImplicitly" : "None"]]))
            return id
        }
        // The BG folder is closed in Pro Tools (its tracks are hidden by the folder).
        struct Family { let name: String; let share: Double; let color: String; let sends: [[String: String]] }
        let families = [
            Family(name: "DX", share: 0.3, color: "#ff3f8fd8",
                   sends: [["A": "DX Verb", "B": "DX Delay"], ["A": "DX Verb"], ["A": "DX Verb", "B": "DX Delay", "C": "Futz"]]),
            Family(name: "FX", share: 0.4, color: "#ffe0a030",
                   sends: [["A": "FX Verb"], ["A": "FX Verb", "B": "Slap"], [:]]),
            Family(name: "BG", share: 0.15, color: "#ff58b868", sends: [["A": "FX Verb"], [:]]),
            Family(name: "MX", share: 0.15, color: "#ffb060d0", sends: [["A": "MX Verb"]]),
        ]
        for f in families {
            let closed = f.name == "BG"
            let folder = add("\(f.name) Folder", "TT_RoutingFolder", color: f.color, format: "TF_None", open: !closed)
            routing["\(f.name) Folder"] = AXRouting(input: nil, outputs: [])
            let count = max(2, Int(Double(sources) * f.share))
            for i in 1...count {
                let name = "\(f.name) \(i)"
                let type = f.name == "MX" && i % 4 == 0 ? "TT_Instrument" : "TT_Audio"
                _ = add(name, type, color: f.color, folder: folder, hiddenByFolder: closed)
                let sends = f.sends[(i - 1) % f.sends.count]
                var states: [String: String] = [:]
                for k in sends.keys { states[k] = k == "B" ? "pre is active" : "" }
                // Pro Tools doesn't show tracks of a closed folder in the Mix window.
                if closed && unreadClosed { continue }
                routing[name] = AXRouting(input: "In \(i)", outputs: ["\(f.name) Bus"], sends: sends, sendStates: states)
            }
        }
        for (name, out) in [("DX Bus", "DX Stem"), ("FX Bus", "FX Stem"), ("BG Bus", "FX Stem"), ("MX Bus", "MX Stem"),
                            ("DX Verb", "DX Stem"), ("DX Delay", "DX Stem"), ("Futz", "DX Stem"), ("FX Verb", "FX Stem"),
                            ("Slap", "FX Stem"), ("MX Verb", "MX Stem")] {
            _ = add(name, "TT_Aux", color: "#ff909090", format: "TF_Stereo")
            routing[name] = AXRouting(input: name, outputs: [out])
        }
        for stem in ["DX Stem", "FX Stem", "MX Stem"] {
            _ = add(stem, "TT_Aux", color: "#ff707070", format: "TF_Stereo")
            routing[stem] = AXRouting(input: stem, outputs: ["Main Mix"], sends: ["A": "Print Stems"], sendStates: ["A": ""])
        }
        _ = add("Main Out", "TT_Master", color: "#ff505050", format: "TF_Stereo")
        routing["Main Out"] = AXRouting(input: nil, outputs: ["Main Mix"])
        return (tracks, routing)
    }
}
