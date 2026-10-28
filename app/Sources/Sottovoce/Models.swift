import CryptoKit
import Foundation

/// Speech models the bundled server can run. None ship with the app: they are downloaded on first use into the
/// Hugging Face cache, the same place `huggingface-cli` and a server started from the command line look, so a model
/// fetched either way serves both.
enum SpeechModel: String, CaseIterable, Identifiable {
    case accurate = "mlx-community/Qwen3-ASR-1.7B-8bit"
    case light = "mlx-community/Qwen3-ASR-0.6B-8bit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accurate: return String(localized: "Qwen3-ASR 1.7B, most accurate (2.3 GB)")
        case .light: return String(localized: "Qwen3-ASR 0.6B, lighter (1.0 GB)")
        }
    }

    /// Download size in GB, rounded the way the README and the menus show it
    var gigabytes: Double {
        switch self {
        case .accurate: return 2.3
        case .light: return 1.0
        }
    }

    /// Fast model behind live preview
    static let preview = "mlx-community/SenseVoiceSmall"
    static let previewGigabytes = 0.9

    /// "3.2 GB" for a model, plus the preview model when live preview is on
    static func downloadSize(_ model: SpeechModel, preview: Bool) -> String {
        String(format: "%.1f GB", model.gigabytes + (preview ? previewGigabytes : 0))
    }
}

/// The Hugging Face cache layout the server reads (src/nn.rs): <cache>/models--org--name/refs/main holds a commit,
/// and snapshots/<commit>/ holds the files.
enum ModelCache {
    /// Same lookup order as the server and huggingface_hub
    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let cache = env["HF_HUB_CACHE"], !cache.isEmpty { return URL(fileURLWithPath: cache) }
        if let home = env["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    static func repoDir(_ repo: String) -> URL {
        root.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }

    /// Complete when refs/main points at a snapshot with a config and weights. The downloader writes refs/main
    /// last, but huggingface-cli writes it first, so an interrupted CLI download would otherwise pass
    static func isComplete(_ repo: String) -> Bool {
        let dir = repoDir(repo)
        guard let rev = try? String(contentsOf: dir.appendingPathComponent("refs/main"), encoding: .utf8) else { return false }
        let snapshot = dir.appendingPathComponent("snapshots").appendingPathComponent(rev.trimmingCharacters(in: .whitespacesAndNewlines))
        let fm = FileManager.default
        // fileExists follows symlinks, so a CLI snapshot entry whose blob is missing counts as absent
        guard fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path),
              let names = try? fm.contentsOfDirectory(atPath: snapshot.path) else { return false }
        return names.contains { $0.hasSuffix(".safetensors") && fm.fileExists(atPath: snapshot.appendingPathComponent($0).path) }
    }
}

/// Downloads model repositories into the cache: files go to snapshots/<commit>/ and refs/main is written last, so the
/// server never picks up a half-finished model. Each file resumes from where it stopped (HTTP Range on a .incomplete
/// file, across retries and app restarts), weights are checked against the SHA-256 Hugging Face publishes, and
/// hf-mirror.com is tried when huggingface.co can't be reached.
enum ModelDownloader {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let endpoints = ["https://huggingface.co", "https://hf-mirror.com"]
    /// Repository files the server never reads
    private static let skipped: Set<String> = [".gitattributes", "README.md"]
    private static let attempts = 5

    /// progress receives (bytes done, bytes total) a few times a second, on an arbitrary thread
    static func download(_ repos: [String], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var plans: [(repo: String, endpoint: String, info: RepoInfo)] = []
        for repo in repos {
            let (endpoint, info) = try await fetchInfo(repo)
            plans.append((repo, endpoint, info))
        }

        let files = plans.flatMap { plan in plan.info.siblings.filter { !skipped.contains($0.rfilename) }.map { (plan, $0) } }
        let total = files.reduce(Int64(0)) { $0 + ($1.1.size ?? 0) }
        let counter = ProgressCounter(total: total, report: progress)
        var pending: Int64 = 0
        for (plan, file) in files {
            let have = existingBytes(snapshot(plan.repo, plan.info.sha), file.rfilename)
            counter.add(have)
            pending += max((file.size ?? 0) - have, 0)
        }
        try checkDiskSpace(pending)
        counter.flush()

        for (plan, file) in files {
            try await fetch(file, repo: plan.repo, commit: plan.info.sha, endpoint: plan.endpoint, counter: counter)
        }
        // Publish the snapshots only once every file is in place
        for plan in plans {
            let refs = ModelCache.repoDir(plan.repo).appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try plan.info.sha.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        }
        counter.flush()
    }

    private struct RepoInfo: Decodable {
        let sha: String
        let siblings: [File]

        struct File: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }

        struct LFS: Decodable {
            let sha256: String
        }
    }

    private static func fetchInfo(_ repo: String) async throws -> (String, RepoInfo) {
        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: "\(endpoint)/api/models/\(repo)/revision/main?blobs=true") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw Failure(message: "HTTP \(code)") }
                let info = try JSONDecoder().decode(RepoInfo.self, from: data)
                try validate(info)
                return (endpoint, info)
            } catch {
                lastError = error
            }
        }
        throw Failure(message: String(localized: "Can't reach Hugging Face: \(lastError?.localizedDescription ?? "")"))
    }

    /// The commit and the file names become paths on disk, so a manifest from a broken or hostile mirror must not
    /// point outside the snapshot directory: the commit is a plain hash, and names are relative paths without
    /// "." / ".." components
    private static func validate(_ info: RepoInfo) throws {
        guard info.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw Failure(message: String(localized: "Invalid commit: \(info.sha)"))
        }
        for file in info.siblings {
            let parts = file.rfilename.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw Failure(message: String(localized: "Invalid file name: \(file.rfilename)"))
            }
        }
    }

    private static func snapshot(_ repo: String, _ commit: String) -> URL {
        ModelCache.repoDir(repo).appendingPathComponent("snapshots").appendingPathComponent(commit)
    }

    /// Bytes already on disk for a file: the finished file, or the partial one
    private static func existingBytes(_ snapshot: URL, _ name: String) -> Int64 {
        let target = snapshot.appendingPathComponent(name)
        return size(of: target) ?? size(of: partial(target)) ?? 0
    }

    private static func partial(_ target: URL) -> URL {
        target.appendingPathExtension("incomplete")
    }

    /// Size of a file, following symlinks (huggingface-cli snapshots link into blobs/)
    private static func size(of url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    private static func checkDiskSpace(_ needed: Int64) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ModelCache.root, withIntermediateDirectories: true)
        let values = try ModelCache.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? .max
        // Keep some room so the download never fills the disk to the last byte
        if needed + 1_000_000_000 > free {
            let size = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            throw Failure(message: String(localized: "Not enough disk space: the models need \(size)"))
        }
    }

    private static func fetch(_ file: RepoInfo.File, repo: String, commit: String, endpoint: String,
                              counter: ProgressCounter) async throws {
        let target = snapshot(repo, commit).appendingPathComponent(file.rfilename)
        if let expected = file.size, size(of: target) == expected { return }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partial(target)
        // A partial file longer than the real one can't be resumed
        if let expected = file.size, let have = size(of: part), have > expected {
            try fm.removeItem(at: part)
            counter.add(-have)
        }
        guard let url = URL(string: "\(endpoint)/\(repo)/resolve/\(commit)/\(file.rfilename)") else {
            throw Failure(message: String(localized: "Invalid file name: \(file.rfilename)"))
        }

        var attempt = 0
        while size(of: part) != file.size || file.size == nil {
            do {
                try await FileFetch.run(url: url, to: part) { counter.add($0) }
                if file.size == nil { break }
                // A response that ended early is retried like a network error
                if size(of: part) != file.size { throw URLError(.networkConnectionLost) }
            } catch let error as URLError where error.code != .cancelled {
                attempt += 1
                guard attempt < attempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }

        if let sha = file.lfs?.sha256 {
            let actual = try await Task.detached(priority: .utility) { try sha256(of: part) }.value
            guard actual == sha else {
                let have = size(of: part) ?? 0
                try? fm.removeItem(at: part)
                counter.add(-have)
                throw Failure(message: String(localized: "Downloaded file is damaged: \(file.rfilename)"))
            }
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: part, to: target)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Byte counter shared by the downloads; reports at most five times a second
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: @Sendable (Int64, Int64) -> Void
    private var done: Int64 = 0
    private var lastReport = Date.distantPast

    init(total: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.total = total
        self.report = report
    }

    func add(_ bytes: Int64) {
        lock.lock()
        done += bytes
        let now = Date()
        let due = now.timeIntervalSince(lastReport) >= 0.2
        if due { lastReport = now }
        let value = done
        lock.unlock()
        if due { report(min(value, total), total) }
    }

    func flush() {
        lock.lock()
        let value = done
        lock.unlock()
        report(min(value, total), total)
    }
}

/// One HTTP GET appended to a file, starting from the file's current length. A server that ignores the Range header
/// (200 instead of 206) gets the file truncated and written from the start
private final class FileFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var offset: UInt64
    private let onBytes: (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(handle: FileHandle, offset: UInt64, onBytes: @escaping (Int64) -> Void) {
        self.handle = handle
        self.offset = offset
        self.onBytes = onBytes
    }

    /// onBytes receives each chunk's length, and minus the discarded length when a download restarts from zero
    static func run(url: URL, to file: URL, onBytes: @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let fetch = FileFetch(handle: handle, offset: try handle.seekToEnd(), onBytes: onBytes)

        var request = URLRequest(url: url)
        if fetch.offset > 0 { request.setValue("bytes=\(fetch.offset)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // Longest stall between two packets
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1   // Chunks are written in order
        let session = URLSession(configuration: config, delegate: fetch, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                fetch.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 206:
            completionHandler(.allow)
        case 200:
            if offset > 0 {
                do { try handle.truncate(atOffset: 0) } catch { failure = error; completionHandler(.cancel); return }
                onBytes(-Int64(offset))
                offset = 0
            }
            completionHandler(.allow)
        default:
            failure = ModelDownloader.Failure(message: String(localized: "Download failed: HTTP \(code)"))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        offset += UInt64(data.count)
        onBytes(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
