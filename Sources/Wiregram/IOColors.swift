import Foundation

/// Bus colours from Pro Tools' I/O settings.
///
/// Pro Tools keeps the I/O Setup of the open session in "Last Used.pio" (Preferences/Avid/Pro
/// Tools). Each path is a record `5A <type:u16> <length:u32> <body>`; the body holds the name
/// (`<u32 length><bytes>` at offset 4) and ends with the path's colour as an index into the
/// Pro Tools colour palette (Int16, -2 = no colour). Read-only.
enum IOColors {
    static var lastUsedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/Avid/Pro Tools/Last Used.pio")
    }

    /// Path name → palette index, for every path that has a colour.
    static func paletteIndices(in data: Data) -> [String: Int] {
        let d = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24 }
        var out: [String: Int] = [:]
        var uncoloured = 0, odd = 0
        var i = 0
        while i + 15 < d.count {
            guard d[i] == 0x5A, u16(i + 1) == 0x0E else { i += 1; continue }
            let n = u32(i + 3), body = i + 7
            guard n > 12, n < 100_000, body + n <= d.count else { i += 1; continue }
            let len = u32(body + 4)
            guard len > 0, len < 256, body + 8 + len <= body + n,
                  let name = String(bytes: d[(body + 8)..<(body + 8 + len)], encoding: .utf8)
                    ?? String(bytes: d[(body + 8)..<(body + 8 + len)], encoding: .macOSRoman)
            else { i += 1; continue }
            let raw = u16(body + n - 2)
            let index = raw >= 0x8000 ? raw - 0x10000 : raw
            if index == -2 { uncoloured += 1 } else if !(0...127).contains(index) { odd += 1 }
            if (0...127).contains(index), out[name] == nil { out[name] = index }
            i = body + n
        }
        // Older Pro Tools versions (without bus colours) end the record differently. Only trust
        // the field when it looks like colours: some paths without one (-2), nothing out of range.
        guard uncoloured > 0, odd == 0 else { return [:] }
        return out
    }

    /// Path name → "#AARRGGBB", for the paths whose colour is in the known palette.
    static func read(_ url: URL = lastUsedURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return paletteIndices(in: data).compactMapValues { palette[$0] }
    }

    /// Pro Tools colour palette: index → colour. The palette window has 3 rows (bright, mid,
    /// dark) of hues; index = 24 × (row + 1) + column (column 1…23). Measured from the palette
    /// window and, where a track used the colour, corrected to the exact value PTSL reports.
    static let palette: [Int: String] = [
        25: "#ff2b32fc", 26: "#ff5533fc", 27: "#ff8735fb", 28: "#ffbf00fc", 29: "#ffbd2dbf", 30: "#ffbc2488",
        31: "#ffbd0054", 32: "#ffbc000d", 33: "#ffbc1e0c", 34: "#ffbc520d", 35: "#ffbd8811", 36: "#ffbfc415",
        37: "#ff89c412", 38: "#ff57c511", 39: "#ff2ec60f", 40: "#ff1cc60e", 41: "#ff1ec654", 42: "#ff1fc388",
        43: "#ff23c3c1", 44: "#ff27c1fd", 45: "#ff2184fc", 46: "#ff1c4afb", 47: "#ff1832fc", 49: "#ff1e00a3",
        50: "#ff361da2", 51: "#ff551fa2", 52: "#ff7400a4", 53: "#ff7c0089", 54: "#ff7b1666", 55: "#ff7a1245",
        56: "#ff7a000b", 57: "#ff7a120a", 58: "#ff7a300d", 59: "#ff7a510e", 60: "#ff898010", 61: "#ff67800d",
        62: "#ff48800e", 63: "#ff2c800d", 64: "#ff18800c", 65: "#ff168032", 66: "#ff167f50", 67: "#ff1a8b7d",
        68: "#ff1d8ca3", 69: "#ff1969a4", 70: "#ff1545a2", 71: "#ff1323a2", 73: "#ff14005f", 74: "#ff21005f",
        75: "#ff310d5f", 76: "#ff41005f", 77: "#ff4b0057", 78: "#ff470a42", 79: "#ff470732", 80: "#ff47000b",
        81: "#ff470c0b", 82: "#ff471d0b", 83: "#ff472c0d", 84: "#ff574d0f", 85: "#ff42490d", 86: "#ff324a0c",
        87: "#ff224a0e", 88: "#ff154b0b", 89: "#ff0d4a1d", 90: "#ff0d4a2b", 91: "#ff14594c", 92: "#ff16585e",
        93: "#ff14475f", 94: "#ff13345e", 95: "#ff11225f",
    ]
}
