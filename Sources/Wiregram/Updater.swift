import AppKit
import Foundation

/// Keeps PT Wiregram up to date from the GitHub releases of the project.
///
/// On first launch the user chooses whether this is on. When it is, the app checks once a day,
/// downloads a newer release in the background and installs it when the app quits (or right
/// away with "Relaunch to Update"). "Check for Updates…" works whether or not it is on.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "fvrijhof/PT-Wiregram"
    private static let enabledKey = "autoUpdate"
    private static let lastCheckKey = "autoUpdateLastCheck"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        /// A newer version is unpacked next to the running app and installs on quit.
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// nil until the user has answered the first-launch question.
    @Published var enabled: Bool? {
        didSet {
            guard enabled != oldValue else { return }
            if let enabled { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
            if enabled == true { checkIfDue(force: true) }
        }
    }
    @Published var showPrompt = false

    private var staged: URL?
    private var timer: Timer?

    /// The running version (from Info.plist); nil when running outside the app bundle.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.installStagedOnQuit() }
        }
    }

    /// Called when the main window appears.
    func launch() {
        guard Self.currentVersion != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        if enabled == nil { showPrompt = true }
        checkIfDue(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkIfDue(force: false) }
        }
    }

    private func checkIfDue(force: Bool) {
        guard enabled == true else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 20 * 3600 else { return }
        check(manual: false)
    }

    // MARK: Checking

    struct Release { let version: String; let zip: URL; let page: URL }

    /// Looks for a newer release. Manual checks show their result; automatic ones only act when
    /// there is an update.
    func check(manual: Bool) {
        switch state { case .checking, .downloading, .ready: return; default: break }
        state = .checking
        Task {
            do {
                let release = try await Self.latestRelease()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let current = Self.currentVersion, Self.isNewer(release.version, than: current) else {
                    state = .upToDate
                    if manual { alert("PT Wiregram is up to date", "You have the latest version (\(Self.currentVersion ?? "?")).") }
                    return
                }
                if manual && enabled != true {
                    let a = NSAlert()
                    a.messageText = "PT Wiregram \(release.version) is available"
                    a.informativeText = "You have version \(current). Download and install it now? The app restarts when it's done."
                    a.addButton(withTitle: "Install and Relaunch")
                    a.addButton(withTitle: "Release Notes")
                    a.addButton(withTitle: "Later")
                    switch a.runModal() {
                    case .alertFirstButtonReturn: break
                    case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page); state = .idle; return
                    default: state = .idle; return
                    }
                    try await download(release)
                    relaunchToUpdate()
                } else {
                    try await download(release)
                }
            } catch {
                state = .failed(error.localizedDescription)
                if manual { alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private static func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PT-Wiregram-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String,
              let zipURL = URL(string: zip)
        else { throw UpdateError("The latest release on GitHub has no downloadable app.") }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), zip: zipURL, page: page)
    }

    /// "1.10" is newer than "1.9"; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Downloading

    private func download(_ release: Release) async throws {
        state = .downloading(release.version)
        let (tmp, resp) = try await URLSession.shared.download(from: release.zip)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PT Wiregram update \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", tmp.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw UpdateError("The downloaded file doesn't contain PT Wiregram.") }
        // Make sure the new app is intact before it replaces this one.
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            throw UpdateError("PT Wiregram can't replace itself in \(Bundle.main.bundleURL.deletingLastPathComponent().path). Move it to your Applications folder, or download the update from GitHub.")
        }
        staged = app
        state = .ready(release.version)
    }

    // MARK: Installing

    /// Quits, swaps in the new version and opens it.
    func relaunchToUpdate() {
        guard staged != nil else { return }
        swap(reopen: true)
        NSApp.terminate(nil)
    }

    private func installStagedOnQuit() { if staged != nil { swap(reopen: false) } }

    /// A small script waits until this process has quit, then replaces the app bundle.
    private func swap(reopen: Bool) {
        guard let new = staged else { return }
        staged = nil
        let dest = Bundle.main.bundlePath
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        old="$2.old-$$"
        /bin/mv "$2" "$old" && /bin/mv "$1" "$2" && /bin/rm -rf "$old" || { [ -d "$old" ] && [ ! -d "$2" ] && /bin/mv "$old" "$2"; }
        [ "$3" = 1 ] && /usr/bin/open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), new.path, dest, reopen ? "1" : "0"]
        try? p.run()
    }

    // MARK: Helpers

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing the update.") }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
