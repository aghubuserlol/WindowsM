import Foundation

/// Talks to the UUP dump API, downloads the update packages that make up a
/// Windows 11 ARM64 build, and drives the bundled UUP converter to produce a
/// bootable ISO locally.
///
/// Downloads use a background URLSession so they survive app relaunches and
/// resume after network drops (Microsoft's CDN supports ranged requests).
final class UUPDownloader: NSObject, ObservableObject {

    enum FileState: Equatable {
        case pending
        case downloading
        case finished
        case failed(String)
    }

    struct FileProgress: Identifiable {
        let entry: UUPFileEntry
        var receivedBytes: Int64 = 0
        var state: FileState = .pending

        var id: String { entry.id }
        var fraction: Double {
            guard entry.sizeBytes > 0 else { return state == .finished ? 1 : 0 }
            return min(1, Double(receivedBytes) / Double(entry.sizeBytes))
        }
    }

    @Published private(set) var build: UUPBuild?
    @Published private(set) var fileProgress: [FileProgress] = []
    @Published private(set) var isDownloading = false
    @Published private(set) var isConverting = false
    @Published var statusMessage = "Idle"

    var overallProgress: Double {
        guard !fileProgress.isEmpty else { return 0 }
        let total = fileProgress.reduce(Int64(0)) { $0 + max($1.entry.sizeBytes, 1) }
        let received = fileProgress.reduce(Int64(0)) { $0 + ($1.state == .finished ? max($1.entry.sizeBytes, 1) : $1.receivedBytes) }
        return Double(received) / Double(total)
    }

    var allFilesFinished: Bool {
        !fileProgress.isEmpty && fileProgress.allSatisfy { $0.state == .finished }
    }

    /// Where packages land and the converter runs.
    ///
    /// IMPORTANT: this path must contain NO SPACES. The UUP converter shell
    /// script is not robust to spaces (e.g. `[ -z $2 ]` word-splits the dir
    /// path), so "~/Library/Application Support/…" silently broke conversion
    /// with "binary operator expected". Caches has no space and is the right
    /// place for large, re-downloadable artifacts.
    let workDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WindowsM/uup", isDirectory: true)
    }()

    /// Legacy location (had a space, broke the converter). One-time migrated.
    private static let legacyWorkDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WindowsM/UUP", isDirectory: true)
    }()

    /// Moves any downloads from the old space-containing path to the new
    /// no-space path (instant rename on the same volume, never re-downloads).
    func migrateLegacyDownloadsIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.legacyWorkDirectory.path) else { return }
        try? fm.createDirectory(at: workDirectory.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: workDirectory.path) {
            try? fm.moveItem(at: Self.legacyWorkDirectory, to: workDirectory)
        } else {
            // New dir already exists: move individual files over, keep both safe.
            if let items = try? fm.contentsOfDirectory(at: Self.legacyWorkDirectory,
                                                       includingPropertiesForKeys: nil) {
                for item in items {
                    let dest = workDirectory.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: item, to: dest)
                    }
                }
            }
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.windowsm.uup-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var tasksByFileName: [String: URLSessionDownloadTask] = [:]
    private var onAllFinished: (() -> Void)?

    // MARK: - API queries

    /// Target Windows release. We always pin Windows 11 version 25H2, whose
    /// retail builds are 26200.x, not "whatever is newest", which would drift
    /// onto Insider/preview channels.
    static let targetVersion = "25H2"
    static let targetBuildPrefix = "26200"

    /// Finds the newest **25H2** Windows 11 ARM64 build on UUP dump.
    func fetchLatestBuild() async throws -> UUPBuild {
        // Bring forward any downloads from the old space-containing path so
        // they are not re-downloaded.
        migrateLegacyDownloadsIfNeeded()
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var components = URLComponents(string: "https://api.uupdump.net/listid.php")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "Windows 11, version \(Self.targetVersion) arm64"),
            URLQueryItem(name: "sortByDate", value: "1"),
        ]
        let data = try await fetch(components.url!)
        let list = try JSONDecoder().decode(UUPListResponse.self, from: data)

        // Keep only ARM64 retail 25H2 builds (build 26200.x, "25H2" in title),
        // excluding Insider/preview channels, then take the newest by date.
        let blocked = ["insider", "preview", "dev channel", "beta", "canary"]
        let candidates = list.builds
            .filter { $0.arch.caseInsensitiveCompare("arm64") == .orderedSame }
            .filter { $0.build.hasPrefix(Self.targetBuildPrefix)
                      || $0.title.localizedCaseInsensitiveContains(Self.targetVersion) }
            .filter { b in !blocked.contains { b.title.localizedCaseInsensitiveContains($0) } }
            .sorted { $0.created > $1.created }

        guard let best = candidates.first else {
            throw WindowsMError.downloadFailed(
                "UUP dump returned no Windows 11 \(Self.targetVersion) (build \(Self.targetBuildPrefix).x) ARM64 builds.")
        }
        await MainActor.run {
            self.build = best
            self.statusMessage = "Selected \(best.title)"
        }
        return best
    }

    /// Resolves the package list (with CDN URLs) for a build.
    func fetchFileList(for build: UUPBuild,
                       language: String = "en-us",
                       edition: String = "professional") async throws -> [UUPFileEntry] {
        var components = URLComponents(string: "https://api.uupdump.net/get.php")!
        components.queryItems = [
            URLQueryItem(name: "id", value: build.uuid),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "edition", value: edition),
        ]
        let data = try await fetch(components.url!)
        let response = try JSONDecoder().decode(UUPGetResponse.self, from: data)
        guard !response.files.isEmpty else {
            throw WindowsMError.downloadFailed("UUP dump returned an empty file list for \(build.title).")
        }
        await MainActor.run {
            self.fileProgress = response.files.map { FileProgress(entry: $0) }
            // Immediately mark files already on disk (from a prior run) as
            // finished, so they are shown as done and never re-downloaded.
            self.reconcileWithDisk()
            let present = self.fileProgress.filter { $0.state == .finished }.count
            let total = ByteCountFormatter.string(
                fromByteCount: response.files.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)
            self.statusMessage = present > 0
                ? "\(response.files.count) packages (\(total)); \(present) already downloaded, will skip"
                : "\(response.files.count) packages, \(total)"
        }
        return response.files
    }

    /// Marks every file already present on disk at its full size as finished.
    /// Idempotent; safe to call repeatedly. This is what guarantees a file is
    /// never downloaded twice across retries or app relaunches.
    func reconcileWithDisk() {
        for i in fileProgress.indices where fileProgress[i].state != .finished {
            let entry = fileProgress[i].entry
            let path = workDirectory.appendingPathComponent(entry.name).path
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64,
               entry.sizeBytes > 0, size == entry.sizeBytes {
                fileProgress[i].state = .finished
                fileProgress[i].receivedBytes = size
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WindowsMError.downloadFailed("UUP dump API returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.lastPathComponent).")
        }
        return data
    }

    // MARK: - Downloading

    /// Kicks off background downloads for every pending file.
    /// `onComplete` fires on the main queue when the last file lands.
    func startDownloads(onComplete: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        onAllFinished = onComplete
        // Re-scan disk first: anything already complete is marked finished and
        // skipped below, files are never downloaded twice.
        reconcileWithDisk()
        let skipped = fileProgress.filter { $0.state == .finished }.count
        DispatchQueue.main.async {
            self.isDownloading = true
            self.statusMessage = skipped > 0
                ? "Downloading… (\(skipped) already on disk, skipped)"
                : "Downloading…"
        }
        for progress in fileProgress where progress.state != .finished {
            let entry = progress.entry
            let task = session.downloadTask(with: entry.url)
            task.taskDescription = entry.name
            tasksByFileName[entry.name] = task
            update(fileNamed: entry.name) { $0.state = .downloading }
            task.resume()
        }
        checkCompletion()
    }

    func cancelDownloads() {
        tasksByFileName.values.forEach { $0.cancel() }
        tasksByFileName.removeAll()
        DispatchQueue.main.async {
            self.isDownloading = false
            self.statusMessage = "Cancelled"
        }
    }

    // MARK: - ISO conversion

    /// A previously built ISO in the work directory, if one exists. Building an
    /// ISO from the UUP packages is expensive (minutes of CPU), so we cache the
    /// result and reuse it across install attempts; it is cleared only after a
    /// successful install (see cleanupAfterSuccessfulInstall).
    func existingBuiltISO() -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: workDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        func size(_ url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "iso" && size($0) > 1_000_000_000 }
            .max { size($0) < size($1) }
    }

    /// Runs the bundled UUP converter (wimlib-based, same scripts UUP dump
    /// ships for Linux/macOS) over the downloaded packages. Returns the ISO.
    func convertToISO(onLog: @escaping (String) -> Void) async throws -> URL {
        // Reuse a cached ISO if one is already built, never reprocess while a
        // good ISO exists.
        if let cached = existingBuiltISO() {
            let bytes = Int64((try? cached.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            await MainActor.run { self.statusMessage = "Reusing built ISO: \(cached.lastPathComponent)" }
            onLog("Found a previously built ISO (\(cached.lastPathComponent), \(sizeText)) — skipping conversion.")
            return cached
        }

        let converter = try BundledResources.require(BundledResources.uupConverterScript,
                                                     name: "uup-converter/convert.sh",
                                                     producedBy: "scripts/fetch-uup-converter.sh")
        await MainActor.run {
            self.isConverting = true
            self.statusMessage = "Building ISO (this takes a while)…"
        }
        defer { Task { @MainActor in self.isConverting = false } }

        // PATH for the converter:
        //  - the app's Resources dir first, so `which wimlib-imagex` finds the
        //    bundled static build (the converter checks PATH, not our bundle);
        //  - Homebrew bins, where aria2c / cabextract / mkisofs live;
        //  - the usual system paths.
        var env = ProcessInfo.processInfo.environment
        let resourcesPath = converter.deletingLastPathComponent().deletingLastPathComponent().path
        let extraPaths = [resourcesPath, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPaths + [(env["PATH"] ?? "")]).joined(separator: ":")

        // arg 3 = create_virtual_editions; "0" avoids the chntpw dependency.
        let status = try await Shell.runStreaming("/bin/bash",
                                                  [converter.path, "wim", workDirectory.path, "0"],
                                                  currentDirectory: workDirectory,
                                                  environment: env,
                                                  onLine: onLog)
        guard status == 0 else {
            throw WindowsMError.isoConversionFailed("Converter exited with status \(status). Open the Welcome screen’s “Download tools” check — aria2, cabextract, and cdrtools (mkisofs) must be installed.")
        }
        let contents = try FileManager.default.contentsOfDirectory(at: workDirectory,
                                                                   includingPropertiesForKeys: nil)
        guard let iso = contents.first(where: { $0.pathExtension.lowercased() == "iso" }) else {
            throw WindowsMError.isoConversionFailed("Converter finished but produced no .iso in \(workDirectory.path).")
        }
        await MainActor.run { self.statusMessage = "ISO ready: \(iso.lastPathComponent)" }
        return iso
    }

    /// Removes only the cached ISO(s), keeping the downloaded UUP packages, so
    /// the next convert rebuilds a fresh ISO without re-downloading. Used by
    /// the "Rebuild ISO" affordance when a cached ISO should be replaced.
    func discardCachedISO() {
        if let contents = try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension.lowercased() == "iso" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        DispatchQueue.main.async { self.statusMessage = "Cached ISO discarded; ready to rebuild." }
    }

    /// Reclaims the cached build artifacts (downloaded UUP packages + built
    /// ISO) once an install has SUCCEEDED. They are deliberately kept across
    /// failed attempts so nothing is re-downloaded or re-converted; only a
    /// success frees them. Never touches a user-provided local ISO (that lives
    /// outside the work directory).
    func cleanupAfterSuccessfulInstall() {
        let fm = FileManager.default
        let freed = (try? fm.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(Int64(0)) { acc, url in
                acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            } ?? 0
        try? fm.removeItem(at: workDirectory)
        try? fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        DispatchQueue.main.async {
            self.fileProgress = []
            self.build = nil
            self.statusMessage = freed > 0
                ? "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of cached build files"
                : "Idle"
        }
    }

    // MARK: - State helpers

    private func update(fileNamed name: String, _ mutate: @escaping (inout FileProgress) -> Void) {
        DispatchQueue.main.async {
            guard let index = self.fileProgress.firstIndex(where: { $0.id == name }) else { return }
            mutate(&self.fileProgress[index])
        }
    }

    private func checkCompletion() {
        DispatchQueue.main.async {
            guard self.isDownloading, self.allFilesFinished else { return }
            self.isDownloading = false
            self.statusMessage = "All packages downloaded"
            self.onAllFinished?()
            self.onAllFinished = nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UUPDownloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        update(fileNamed: name) { $0.receivedBytes = totalBytesWritten }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        let destination = workDirectory.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            update(fileNamed: name) { $0.state = .finished }
        } catch {
            update(fileNamed: name) { $0.state = .failed(error.localizedDescription) }
        }
        DispatchQueue.main.async { self.tasksByFileName[name] = nil }
        checkCompletion()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        update(fileNamed: name) { $0.state = .failed(error.localizedDescription) }
        DispatchQueue.main.async {
            self.tasksByFileName[name] = nil
            self.statusMessage = "“\(name)” failed: \(error.localizedDescription)"
        }
    }
}
