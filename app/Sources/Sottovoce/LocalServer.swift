import Darwin
import Foundation

/// Runs the speech recognition server bundled in the app (Contents/MacOS/sottovoce-server) while the connection is
/// "This Mac": downloads the models it needs, starts it on the port setting (8008 by default; loopback only, or every
/// interface when sharing is on), restarts it when a setting it depends on changes or it exits unexpectedly, and stops
/// it with the app. A Sottovoce server that already answers on the port, such as one started from the command line or
/// a LaunchAgent, is used as is and left alone.
@MainActor
final class LocalServer: ObservableObject {
    enum State: Equatable {
        /// Remote connection: nothing runs on this Mac
        case off
        /// Models are missing and the user hasn't chosen a size and started the download yet
        case needsDownload
        case downloading(done: Int64, total: Int64)
        case downloadFailed(String)
        case starting
        case running
        /// Another server already answers on the port
        case external
        case failed(String)
    }

    @Published private(set) var state = State.off
    /// Whether a server answers on the port right now; dictation is blocked with a reason while it doesn't
    @Published private(set) var serving = false
    /// The token the sharing section may hand out. Nil states mean "don't show one": a server already on the port
    /// keeps its own token, and the app's token would be refused.
    @Published private(set) var share = Share.none

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sottovoce/server.log")
    }

    /// What the server is started with; a change restarts it
    private struct Config: Equatable {
        var port: Int
        var model: String
        var preview: String
        var share: Bool
        var token: String
    }

    private var process: Process?
    private var processConfig: Config?
    /// Set while a restart is waiting for the old process to exit, so that exit isn't counted as a crash
    private var stopping = false
    private var crashes: [Date] = []
    private var download: Task<Void, Never>?
    /// Bumped per download, so a cancelled one finishing late can't clear the handle of the one that replaced it
    private var downloadID = 0
    private var downloadError: String?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var syncing = false
    private var lastWanted: Config?
    private var log: FileHandle?
    /// Bumped to drop a share check that finished after a newer one started, or after sharing was turned off
    private var shareGeneration = 0
    private var shareInFlight = false
    /// A token the server accepted can stop being accepted, so a settled result is rechecked, just not on every poll
    private var lastShareCheck = Date.distantPast

    func start() {
        // Settings live in UserDefaults; any change may affect the server
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await sync() }
    }

    /// At app quit: SIGTERM lets the server finish in-flight requests and exit
    func stop() {
        stopping = true
        process?.terminate()
    }

    /// After a failed download or repeated crashes, the Retry button in Settings
    func retry() {
        downloadError = nil
        crashes.removeAll()
        Task { await sync() }
    }

    /// The welcome window's or Settings' Download button: allows this and later downloads
    func approveDownload() {
        UserDefaults.standard.set(true, forKey: Pref.downloadApproved)
        Task { await sync() }
    }

    /// Short reason for the HUD when dictation can't reach a server on this Mac yet; nil when it can
    var notReadyMessage: String? {
        serving ? nil : Self.message(for: state)
    }

    /// One-line state for the HUD and the menu; nil when there is nothing to report
    static func message(for state: State) -> String? {
        switch state {
        case .off, .running, .external: return nil
        case .needsDownload: return String(localized: "Model not downloaded")
        case .downloading(let done, let total):
            return String(localized: "Downloading model \(Int(Double(done) / Double(max(total, 1)) * 100))%")
        case .downloadFailed: return String(localized: "Model download failed")
        case .starting: return String(localized: "Server starting…")
        case .failed: return String(localized: "Server stopped")
        }
    }

    /// Whether the preview model is downloaded and loaded with the current settings
    var wantsPreview: Bool { !wanted.preview.isEmpty }

    private var wanted: Config {
        let d = UserDefaults.standard
        // Shared servers keep the preview model so other Macs get live preview even when this one has it off
        let share = d.bool(forKey: Pref.shareServer)
        let preview = d.bool(forKey: Pref.livePreview) || share
        // The token only matters while sharing; leaving it out otherwise keeps a token change from restarting the server
        return Config(port: Pref.localPort, model: Pref.speechModel.rawValue, preview: preview ? SpeechModel.preview : "",
                      share: share, token: share ? Pref.serverToken : "")
    }

    /// Brings the running server in line with the settings; runs every two seconds and on every settings change
    private func sync() async {
        guard !syncing else { return }
        syncing = true
        defer {
            syncing = false
            noteShare()
        }

        guard Pref.connectionMode == .local else {
            // The server on this Mac isn't wanted, but a download in flight is: switching to a remote server and
            // back must not throw away gigabytes already fetched, and must not look like the download finished
            terminate()
            serving = false
            if case .downloading = state {} else { state = .off }
            return
        }

        let want = wanted
        // A settings change is a fresh start for a failed download or a crashing server
        if want != lastWanted {
            lastWanted = want
            downloadError = nil
            crashes.removeAll()
            // e.g. switching to the lighter model mid-download: stop fetching what is no longer wanted; partial
            // files stay and resume if it is wanted again
            download?.cancel()
            download = nil
        }

        if let process, process.isRunning {
            // A model change waits for its download while the old process keeps serving, but turning sharing off or
            // replacing the token takes effect at once: otherwise the old process would stay reachable from the
            // network with the old token until the download finished, or forever if it failed
            // A new port also takes effect at once, since the app already talks to the new one
            let revoked = processConfig.map { $0.share && (!want.share || $0.token != want.token) } ?? false
            let moved = processConfig.map { $0.port != want.port } ?? false
            if processConfig != want && (missing(want).isEmpty || revoked || moved) {
                terminate()   // The termination handler clears the process; the next sync starts the new one
                return
            }
            serving = await probe(port: want.port) == .sottovoce
            if missing(want).isEmpty { state = serving ? .running : .starting } else { ensureDownload(want) }
            return
        }

        switch await probe(port: want.port) {
        case .sottovoce:
            // Someone else's server on the port: use it, and don't download models it doesn't need
            serving = true
            state = .external
            return
        case .other:
            // Another app holds the port. Checked before launching, since the server loads its models (seconds,
            // gigabytes) before it tries to listen
            serving = false
            state = .failed(String(localized: "Port \(String(want.port)) is used by another app; choose another port"))
            return
        case .free:
            serving = false
        }
        guard missing(want).isEmpty else {
            ensureDownload(want)
            return
        }
        crashes = crashes.filter { $0.timeIntervalSinceNow > -60 }
        if crashes.count >= 3 {
            state = .failed(lastLogError() ?? String(localized: "The server keeps exiting"))
            return
        }
        launch(want)
    }

    private func missing(_ config: Config) -> [String] {
        [config.model, config.preview].filter { !$0.isEmpty && !ModelCache.isComplete($0) }
    }

    /// Starts downloading what the settings need, unless a download is running or the last one failed. A server
    /// already running keeps serving with its current models until the new ones are in
    private func ensureDownload(_ config: Config) {
        guard download == nil else { return }
        if let downloadError {
            state = .downloadFailed(downloadError)
        } else if !UserDefaults.standard.bool(forKey: Pref.downloadApproved) {
            // Gigabytes: wait for the user to pick a size and press Download
            state = .needsDownload
        } else {
            startDownload(missing(config))
        }
    }

    private func startDownload(_ repos: [String]) {
        state = .downloading(done: 0, total: 0)
        downloadID += 1
        let id = downloadID
        download = Task { [weak self] in
            do {
                try await ModelDownloader.download(repos) { done, total in
                    Task { @MainActor in
                        guard let self, self.downloadID == id, case .downloading = self.state else { return }
                        self.state = .downloading(done: done, total: total)
                    }
                }
            } catch {
                guard let self, self.downloadID == id, !Task.isCancelled else { return }
                self.downloadError = error.localizedDescription
                self.state = .downloadFailed(error.localizedDescription)
            }
            guard let self, self.downloadID == id else { return }
            self.download = nil
            // .starting means "the download is in, the server comes up next", which is only true while this Mac's
            // server is wanted. In remote mode the download merely finishes in the background
            if case .downloading = self.state, Pref.connectionMode == .local { self.state = .starting }
            await self.sync()
        }
    }

    private func launch(_ config: Config) {
        guard let exe = Bundle.main.url(forAuxiliaryExecutable: "sottovoce-server") else {
            state = .failed(String(localized: "The server is missing from the app"))
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--host", config.share ? "0.0.0.0" : "127.0.0.1", "--port", String(config.port),
                       "--model", config.model, "--preview-model", config.preview, "--exit-with-parent"]
        var env = ProcessInfo.processInfo.environment
        env["SOTTOVOCE_TOKEN"] = config.share ? config.token : nil
        p.environment = env
        log = openLog()
        if let log {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] exited in
            Task { @MainActor in self?.exited(exited) }
        }
        do {
            try p.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        process = p
        processConfig = config
        state = .starting
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        if !stopping { crashes.append(Date()) }
        stopping = false
        process = nil
        processConfig = nil
        try? log?.close()
        log = nil
        serving = false
        Task { await sync() }
    }

    private func terminate() {
        guard let process, process.isRunning else { return }
        stopping = true
        process.terminate()
    }

    /// What the sharing section may show. `external` is a server this app did not start: its token is not the one
    /// the switch would have configured.
    enum Share: Equatable {
        case none
        case checking
        case ready(token: String, external: Bool)
        /// The server on the port refused every token this app can see
        case rejected
        /// No address of this Mac answered, so the token cannot be checked. Loopback cannot be used for that:
        /// it skips the bearer check and would accept a token the server refuses from anywhere else
        case unreachable
    }

    private enum ShareVerdict: Equatable {
        case accepted, rejected, unreachable
    }

    /// Learns which token the server on this port actually accepts, and only then allows it to be copied.
    /// Checked from this Mac's own LAN addresses: a request to 127.0.0.1 never needs the token, so it cannot
    /// tell a wrong one from the right one. A server already listening is left alone; when it is this app's
    /// LaunchAgent, that plist's token is checked and shown instead of one the agent would refuse.
    private func noteShare() {
        guard Pref.connectionMode == .local, UserDefaults.standard.bool(forKey: Pref.shareServer) else {
            shareGeneration += 1
            shareInFlight = false
            share = .none
            lastShareCheck = .distantPast
            return
        }
        let token = Pref.serverToken
        if shareInFlight { return }
        // While the server is still coming up there is nothing to recheck slowly: the next poll should try again.
        // A result is only slow to recheck once the server has given an answer.
        if Date().timeIntervalSince(lastShareCheck) < 10 {
            switch share {
            case .ready(let current, false) where current == token: return
            case .ready(_, true), .rejected: return
            default: break
            }
        }
        let known = share
        shareGeneration += 1
        let generation = shareGeneration
        shareInFlight = true
        lastShareCheck = Date()
        // Keep a settled result on screen while a recheck is in flight; flipping back to "checking" every poll just flickers
        if case .ready = known {
        } else if case .rejected = known {
        } else if case .unreachable = known {
        } else {
            share = .checking
        }
        let port = Pref.localPort
        let addresses = NetworkAddresses.current()
        Task { [weak self] in
            let verdict = await Self.shareVerdict(ownToken: token, port: port, addresses: addresses)
            guard let self, self.shareGeneration == generation else { return }
            self.shareInFlight = false
            guard Pref.connectionMode == .local, UserDefaults.standard.bool(forKey: Pref.shareServer) else { return }
            switch verdict {
            case .ready(let accepted, let external):
                self.share = .ready(token: accepted, external: external)
            case .rejected:
                self.share = .rejected
            case .unreachable:
                self.share = .unreachable
            }
        }
    }

    private enum ResolvedShare: Equatable {
        case ready(token: String, external: Bool)
        case rejected
        case unreachable
    }

    /// The app's own token first. Only a refusal is conclusive: the server is up and does not want it, so try the
    /// token of the LaunchAgent installed for this port before admitting there is nothing to copy.
    private static func shareVerdict(ownToken: String, port: Int, addresses: [String]) async -> ResolvedShare {
        switch await bearerVerdict(ownToken, port: port, addresses: addresses) {
        case .accepted:
            return .ready(token: ownToken, external: false)
        case .unreachable:
            return .unreachable
        case .rejected:
            guard let token = installedAgentToken(), token != ownToken else { return .rejected }
            switch await bearerVerdict(token, port: port, addresses: addresses) {
            case .accepted: return .ready(token: token, external: true)
            case .rejected: return .rejected
            case .unreachable: return .unreachable
            }
        }
    }

    /// One acceptance wins; a refusal wins over a timeout, since a server that answered has the say
    private static func bearerVerdict(_ token: String, port: Int, addresses: [String]) async -> ShareVerdict {
        guard !addresses.isEmpty else { return .unreachable }
        return await withTaskGroup(of: ShareVerdict.self) { group in
            for address in addresses {
                group.addTask { await bearerVerdict(token, address: address, port: port) }
            }
            var rejected = false
            for await verdict in group {
                if case .accepted = verdict {
                    group.cancelAll()
                    return .accepted
                }
                if case .rejected = verdict { rejected = true }
            }
            return rejected ? .rejected : .unreachable
        }
    }

    /// Bypasses the system proxy: the check has to hit this Mac, not whatever a proxy would do with a LAN address
    private static let direct: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0,
        ]
        return URLSession(configuration: config)
    }()

    private static func bearerVerdict(_ token: String, address: String, port: Int) async -> ShareVerdict {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = address
        parts.port = port
        parts.path = "/v1/models"
        guard let url = parts.url else { return .unreachable }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await direct.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .unreachable }
        if code == 401 { return .rejected }
        // Anything other than this server's model list is not an acceptance: another app on the port, or a proxy
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["object"] as? String == "list" else { return .unreachable }
        return .accepted
    }

    /// Token of the LaunchAgent this repo installs, if one is configured. Shown only after the server on the port
    /// accepts it: the plist can be stale relative to the running process.
    private static func installedAgentToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/sh.asgard.sottovoce.server.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any],
              let token = env["SOTTOVOCE_TOKEN"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Probe { case sottovoce, other, free }

    /// What answers on the port: a Sottovoce server (its /health returns {"ok": true, "model": ...}), something else,
    /// or nothing. Another app's /health may well return 200 too, and must not be mistaken for a server to dictate with
    private func probe(port: Int) async -> Probe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .free }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true, json["model"] is String else { return .other }
            return .sottovoce
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .free
        } catch {
            return .other
        }
    }

    /// Appends to ~/Library/Logs/Sottovoce/server.log, starting over once it passes 5 MB
    private func openLog() -> FileHandle? {
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 5_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Why the server last failed, from its log: the CLI's "Error: ..." report with its causes on one line, or the
    /// message of the last ERROR line
    private func lastLogError() -> String? {
        guard let text = try? String(contentsOf: Self.logURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").suffix(30).map(String.init)
        if let i = lines.lastIndex(where: { $0.hasPrefix("Error: ") }) {
            let causes = lines[(i + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "Caused by:" }
                .map { $0.replacingOccurrences(of: #"^\d+: "#, with: "", options: .regularExpression) }
            return ([String(lines[i].dropFirst(7))] + causes).joined(separator: ": ")
        }
        // "2026-10-28 07:38:00,123 ERROR message"
        guard let line = lines.last(where: { $0.contains(" ERROR ") }), let r = line.range(of: " ERROR ") else { return nil }
        return String(line[r.upperBound...])
    }
}

/// Addresses other devices can use to reach this Mac's server, for the sharing section in Settings: the IPv4
/// address of every active interface (LAN, Tailscale) except loopback and addresses no other device can reach
enum NetworkAddresses {
    static func current() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(cString: host)
            // 169.254/16 is self-assigned (no network on that interface); 198.18/15 is the fake-IP range of proxy
            // TUN interfaces such as Clash or Surge, never reachable from another device
            let fake = ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.")
            if !ip.hasPrefix("169.254."), !fake, !result.contains(ip) { result.append(ip) }
        }
        return result
    }
}
