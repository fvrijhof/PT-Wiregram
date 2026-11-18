import Foundation

/// Minimal, dependency-free client for the Pro Tools Scripting Library (PTSL).
/// PTSL is gRPC over cleartext HTTP/2 on localhost:31416. Request/Response are tiny
/// protobuf envelopes carrying JSON, so we hand-roll protobuf + a bare HTTP/2 stream.
final class PTSLClient {
    enum Command: Int {
        case getTrackList = 3
        case hostReadyCheck = 13
        case getSessionName = 42
        case getTransportState = 59
        case togglePlayState = 64
        case registerConnection = 70
        case selectTracksByName = 73
        case setTrackHiddenState = 92
        case setTrackOpenState = 96
    }

    struct PTSLError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let host = "127.0.0.1"
    let port: UInt16 = 31416
    private var sessionID: String?

    // MARK: Public API

    func sessionName() throws -> String {
        let json = try call(.getSessionName, body: nil)
        return (json["session_name"] as? String) ?? ""
    }

    func trackList() throws -> [PTTrack] {
        var all: [PTTrack] = []
        var offset = 0
        while true {
            let body: [String: Any] = [
                "track_filter_list": [["filter": "All", "is_inverted": false]],
                "pagination_request": ["limit": 500, "offset": offset],
            ]
            let json = try call(.getTrackList, body: body)
            let list = (json["track_list"] as? [[String: Any]]) ?? []
            all += list.map(PTTrack.init(json:))
            let total = ((json["pagination_response"] as? [String: Any])?["total"] as? Int) ?? all.count
            offset += list.count
            if list.isEmpty || offset >= total { break }
        }
        return all
    }

    /// The transport state as PTSL names it, e.g. "TS_TransportStopped" or "TS_TransportPlaying".
    func transportState() throws -> String {
        let json = try call(.getTransportState, body: nil)
        return (json["current_setting"] as? String) ?? ""
    }

    /// Starts or stops playback (like the space bar).
    func togglePlayState() throws {
        _ = try call(.togglePlayState, body: nil)
    }

    func selectedTrackNames() throws -> [String] {
        let body: [String: Any] = [
            "track_filter_list": [["filter": "Selected", "is_inverted": false]],
            "pagination_request": ["limit": 1000, "offset": 0],
        ]
        let json = try call(.getTrackList, body: body)
        return ((json["track_list"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    func selectTracks(_ names: [String]) throws {
        _ = try call(.selectTracksByName, body: ["track_names": names, "selection_mode": "SM_Replace",
                                                  "pagination_request": ["limit": 1000, "offset": 0]])
    }

    func setOpen(_ names: [String], open: Bool) throws {
        guard !names.isEmpty else { return }
        _ = try call(.setTrackOpenState, body: ["track_names": names, "enabled": open])
    }

    func setHidden(_ names: [String], hidden: Bool) throws {
        _ = try call(.setTrackHiddenState, body: ["track_names": names, "enabled": hidden])
    }

    // MARK: Request plumbing

    private func ensureRegistered() throws {
        if sessionID != nil { return }
        let json = try rawCall(.registerConnection,
                               body: ["company_name": "Wiregram", "application_name": "Wiregram"],
                               session: "")
        guard let sid = json["session_id"] as? String else {
            throw PTSLError(message: "RegisterConnection returned no session_id")
        }
        sessionID = sid
    }

    private func call(_ cmd: Command, body: [String: Any]?) throws -> [String: Any] {
        try ensureRegistered()
        do {
            return try rawCall(cmd, body: body, session: sessionID ?? "")
        } catch {
            // Session id may be stale after a Pro Tools restart: re-register once.
            sessionID = nil
            try ensureRegistered()
            return try rawCall(cmd, body: body, session: sessionID ?? "")
        }
    }

    private func rawCall(_ cmd: Command, body: [String: Any]?, session: String) throws -> [String: Any] {
        var header = ProtoWriter()
        header.varint(field: 2, cmd.rawValue)
        header.varint(field: 3, 1)
        if !session.isEmpty { header.string(field: 4, session) }
        var req = ProtoWriter()
        req.bytes(field: 1, header.data)
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body)
            req.bytes(field: 2, data)
        }

        let respBytes = try H2Unary.call(host: host, port: port,
                                         path: "/ptsl.PTSL/SendGrpcRequest",
                                         message: req.data)
        let resp = ProtoReader.fields(respBytes)
        var status = 0
        if let h = resp[1]?.first { status = ProtoReader.fields(h)[3]?.first.map(ProtoReader.varintValue) ?? 0 }
        let bodyJSON = resp[2]?.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errJSON = resp[3]?.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        // TaskStatus: 3 = Completed
        if status != 3 {
            var msg = "PTSL error (status \(status))"
            if let d = errJSON.data(using: .utf8),
               let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let m = e["command_error_message"] as? String { msg = m }
            throw PTSLError(message: msg)
        }
        guard let d = bodyJSON.data(using: .utf8), !bodyJSON.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }
}

struct PTTrack: Hashable {
    let id: String
    let name: String
    let type: String
    let index: Int
    let color: String
    let format: String
    let parentFolderID: String
    let isInactive: Bool
    let isHidden: Bool
    /// Hidden by the user (not just because a parent folder is hidden/closed).
    let isHiddenExplicitly: Bool
    let isOpen: Bool
    let isMuted: Bool
    let isSoloed: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        name = json["name"] as? String ?? "?"
        type = json["type"] as? String ?? "TT_Unknown"
        index = json["index"] as? Int ?? 0
        color = json["color"] as? String ?? "#ff808080"
        format = json["format"] as? String ?? ""
        parentFolderID = json["parent_folder_id"] as? String ?? ""
        let attrs = json["track_attributes"] as? [String: Any] ?? [:]
        isInactive = (attrs["is_inactive"] as? String ?? "None") != "None"
        isHidden = (attrs["is_hidden"] as? String ?? "None") != "None"
        isHiddenExplicitly = (attrs["is_hidden"] as? String ?? "").hasPrefix("SetExplicitly")
        isOpen = attrs["is_open"] as? Bool ?? true
        isMuted = attrs["is_muted"] as? Bool ?? false
        isSoloed = attrs["is_soloed"] as? Bool ?? false
    }
}

// MARK: - Protobuf helpers

struct ProtoWriter {
    var data = Data()
    mutating func rawVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func varint(field: Int, _ v: Int) { rawVarint(UInt64(field << 3)); rawVarint(UInt64(v)) }
    mutating func bytes(field: Int, _ d: Data) { rawVarint(UInt64(field << 3 | 2)); rawVarint(UInt64(d.count)); data.append(d) }
    mutating func string(field: Int, _ s: String) { bytes(field: field, Data(s.utf8)) }
}

enum ProtoReader {
    /// Returns field number -> list of raw payloads (varints are stored as their encoded bytes).
    static func fields(_ d: Data) -> [Int: [Data]] {
        let b = [UInt8](d)
        var i = 0
        var out: [Int: [Data]] = [:]
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return r }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let tag = readVarint() else { break }
            let field = Int(tag >> 3), wt = tag & 7
            switch wt {
            case 0:
                let s = i
                guard readVarint() != nil else { return out }
                out[field, default: []].append(Data(b[s..<i]))
            case 2:
                guard let l = readVarint(), i + Int(l) <= b.count else { return out }
                out[field, default: []].append(Data(b[i..<(i + Int(l))]))
                i += Int(l)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    static func varintValue(_ d: Data) -> Int {
        var r = 0, shift = 0
        for x in d { r |= Int(x & 0x7f) << shift; shift += 7 }
        return r
    }
}

// MARK: - Bare-bones HTTP/2 (h2c, prior knowledge) unary gRPC call over a blocking socket

enum H2Unary {
    struct H2Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func call(host: String, port: UInt16, path: String, message: Data, timeout: Int = 15) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw H2Error(message: "socket() mislukt") }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw H2Error(message: "Pro Tools (PTSL) not reachable on port \(port)") }

        var out = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        // SETTINGS: ENABLE_PUSH=0, INITIAL_WINDOW_SIZE=2^31-1
        var settings = Data()
        settings.append(contentsOf: [0x00, 0x02, 0, 0, 0, 0])
        settings.append(contentsOf: [0x00, 0x04, 0x7f, 0xff, 0xff, 0xff])
        out.append(frame(type: 0x4, flags: 0, stream: 0, payload: settings))
        // Connection-level WINDOW_UPDATE so large track lists are never flow-control blocked.
        out.append(frame(type: 0x8, flags: 0, stream: 0, payload: be32(0x7fff0000)))

        var hpack = Data()
        for (k, v) in [(":method", "POST"), (":scheme", "http"), (":path", path),
                       (":authority", "\(host):\(port)"), ("content-type", "application/grpc"),
                       ("te", "trailers")] {
            hpack.append(0x00) // literal without indexing, new name
            hpackString(&hpack, k)
            hpackString(&hpack, v)
        }
        out.append(frame(type: 0x1, flags: 0x4, stream: 1, payload: hpack))

        var grpcMsg = Data([0])
        grpcMsg.append(be32(UInt32(message.count)))
        grpcMsg.append(message)
        // Split DATA into 16 KiB frames (default SETTINGS_MAX_FRAME_SIZE).
        var offset = 0
        repeat {
            let end = min(offset + 16384, grpcMsg.count)
            let last = end == grpcMsg.count
            out.append(frame(type: 0x0, flags: last ? 0x1 : 0, stream: 1, payload: grpcMsg.subdata(in: offset..<end)))
            offset = end
        } while offset < grpcMsg.count
        try writeAll(fd, out)

        var body = Data()
        var done = false
        while !done {
            let h = try readExact(fd, 9)
            let len = Int(h[0]) << 16 | Int(h[1]) << 8 | Int(h[2])
            let type = h[3], flags = h[4]
            let stream = (UInt32(h[5]) << 24 | UInt32(h[6]) << 16 | UInt32(h[7]) << 8 | UInt32(h[8])) & 0x7fffffff
            var payload = len > 0 ? try readExact(fd, len) : Data()
            switch type {
            case 0x0: // DATA
                if flags & 0x8 != 0, let pad = payload.first { payload = payload.subdata(in: 1..<(payload.count - Int(pad))) }
                if stream == 1 { body.append(payload) }
                if stream == 1 && flags & 0x1 != 0 { done = true }
            case 0x1: // HEADERS (response headers or trailers)
                if stream == 1 && flags & 0x1 != 0 { done = true }
            case 0x3: // RST_STREAM
                if stream == 1 { throw H2Error(message: "PTSL stream gereset") }
            case 0x4: // SETTINGS
                if flags & 0x1 == 0 { try writeAll(fd, frame(type: 0x4, flags: 0x1, stream: 0, payload: Data())) }
            case 0x6: // PING
                if flags & 0x1 == 0 { try writeAll(fd, frame(type: 0x6, flags: 0x1, stream: 0, payload: payload)) }
            case 0x7: // GOAWAY
                if body.isEmpty { throw H2Error(message: "PTSL verbinding gesloten (GOAWAY)") }
                done = true
            default: break
            }
        }
        guard body.count >= 5 else { throw H2Error(message: "Empty PTSL response") }
        let mlen = Int(body[1]) << 24 | Int(body[2]) << 16 | Int(body[3]) << 8 | Int(body[4])
        guard body.count >= 5 + mlen else { throw H2Error(message: "Incomplete PTSL response") }
        return body.subdata(in: 5..<(5 + mlen))
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    private static func frame(type: UInt8, flags: UInt8, stream: UInt32, payload: Data) -> Data {
        var d = Data([UInt8(payload.count >> 16 & 0xff), UInt8(payload.count >> 8 & 0xff), UInt8(payload.count & 0xff), type, flags])
        d.append(be32(stream & 0x7fffffff))
        d.append(payload)
        return d
    }

    private static func hpackString(_ d: inout Data, _ s: String) {
        let bytes = Array(s.utf8)
        // 7-bit prefix integer, H=0 (no Huffman)
        var n = bytes.count
        if n < 127 { d.append(UInt8(n)) } else {
            d.append(127); n -= 127
            while n >= 128 { d.append(UInt8(n % 128 + 128)); n /= 128 }
            d.append(UInt8(n))
        }
        d.append(contentsOf: bytes)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < data.count {
                let n = send(fd, p.baseAddress! + sent, data.count - sent, 0)
                if n <= 0 { throw H2Error(message: "Writing to PTSL failed") }
                sent += n
            }
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n <= 0 { throw H2Error(message: "Reading from PTSL failed / timeout") }
            got += n
        }
        return Data(buf)
    }
}
