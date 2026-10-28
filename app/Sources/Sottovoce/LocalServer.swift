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
        defer { syncing = false }

        guard Pref.connectionMode == .local else {
            download?.cancel()
            download = nil
            terminate()
            serving = false
            state = .off
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
            if case .downloading = self.state { self.state = .starting }
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
