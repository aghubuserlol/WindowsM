import Foundation

/// Runs the bundled `wm-install.sh` as root via a single administrator
/// authentication (`osascript … with administrator privileges`) and streams
/// its structured progress back to the UI.
///
/// Why this exists alongside HelperClient: `SMJobBless` refuses to install an
/// ad-hoc-signed helper, so the XPC path only works on a properly signed /
/// notarised build. This path performs the identical privileged steps on an
/// unsigned local build with one password prompt, it is what makes the app
/// actually install today. The script speaks a tiny protocol:
///
///     @@STAGE <InstallStage rawId>
///     @@PROGRESS <0..1>
///     <anything else>            → log line
final class PrivilegedInstaller {

    struct Configuration {
        let disk: DiskInfo
        let isoURL: URL
        let resourcesDir: URL
        let imageIndex: Int
        let dryRun: Bool
    }

    var onStage: (InstallStage) -> Void = { _ in }
    var onProgress: (Double) -> Void = { _ in }
    var onLog: (String, LogLevel) -> Void = { _, _ in }

    // Handed off from the privileged script: where the staged ESP tree lives,
    // and which partition to write it to. The app finishes the ESP write from
    // its own user session (the only context macOS/FSKit permits).
    private var espStagingPath: String?
    private var espPartition: String?

    private static let stageByName: [String: InstallStage] = [
        "mountingISO": .mountingISO,
        "partitioning": .partitioning,
        "applyingImage": .applyingImage,
        "extractingBootFiles": .extractingBootFiles,
        "installingBootchain": .installingBootchain,
        "configuringBoot": .configuringBoot,
        "finished": .finished,
    ]

    func install(_ config: Configuration) async throws {
        let script = config.resourcesDir.appendingPathComponent("wm-install.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw WindowsMError.resourceMissing(name: "wm-install.sh",
                                                hint: "It should ship in the app bundle Resources.")
        }

        // Per-run scratch: a log file we tail, and a job wrapper that sets the
        // WM_* environment then execs the installer with output redirected to
        // the log. The wrapper keeps every real path single-quoted so nothing
        // has to survive AppleScript string quoting.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let logURL = scratch.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let jobURL = scratch.appendingPathComponent("job.sh")

        let job = """
        #!/bin/bash
        export WM_DISK=\(shellQuote(config.disk.bsdName))
        export WM_ISO=\(shellQuote(config.isoURL.path))
        export WM_RESOURCES=\(shellQuote(config.resourcesDir.path))
        export WM_IMAGE_INDEX=\(shellQuote(String(config.imageIndex)))
        export WM_DRY_RUN=\(shellQuote(config.dryRun ? "1" : "0"))
        exec /bin/bash \(shellQuote(script.path)) > \(shellQuote(logURL.path)) 2>&1
        """
        try job.write(to: jobURL, atomically: true, encoding: .utf8)

        onLog(config.dryRun ? "Starting dry run (no disk will be erased, no password needed)…"
                            : "Requesting administrator authorization…", .info)

        // Tail the log concurrently with the privileged run.
        let tailer = LogTailer(url: logURL) { [weak self] line in
            self?.handle(line: line)
        }
        tailer.start()
        defer { tailer.stop() }

        // A dry run is non-privileged: run it directly, no password prompt.
        // A real run goes through one administrator authentication.
        let status = config.dryRun
            ? try await runDirect(jobPath: jobURL.path)
            : try await runAdmin(jobPath: jobURL.path)
        // Drain anything written between the last poll and exit.
        tailer.drain()

        if status != 0 {
            throw WindowsMError.installFailed(
                status == kUserCancelledStatus
                ? "Administrator authorization was cancelled."
                : "The install script exited with status \(status). See the log above.")
        }

        // Phase 2, write the EFI System Partition from THIS process (the app
        // runs in the user's session, which is the only context that can write
        // the FSKit FAT mount; no Full Disk Access needed). The privileged
        // script has staged the files and unmounted the ESP.
        if !config.dryRun {
            try await writeESPFromUserSession()
        } else {
            onProgress(1.0)
            onStage(.finished)
            onLog("Dry run complete.", .success)
        }
    }

    /// Copies the staged EFI/m1n1 tree onto the ESP through a normal mount, as
    /// the logged-in user (this process). Proven to work without elevation.
    private func writeESPFromUserSession() async throws {
        guard let staging = espStagingPath, let part = espPartition else {
            throw WindowsMError.installFailed("The privileged phase did not hand off the staged boot files.")
        }
        defer { try? FileManager.default.removeItem(atPath: staging) }

        onStage(.installingBootchain)
        onLog("Formatting and writing the EFI partition from your user session…", .info)

        // diskutil's auto-created EFI System Partition is allocated but
        // UNFORMATTED (no FAT), so it won't mount. Format it to a fresh FAT32 -
        // this also mounts it, and it runs from the user session via diskutil's
        // privileged daemon (no admin prompt). The GPT type becomes Basic Data,
        // which is fine: U-Boot finds the boot files by scanning FAT
        // partitions, not by the EFI type GUID.
        if try runUser("/usr/sbin/diskutil", ["eraseVolume", "FAT32", "EFI", part]) != 0 {
            throw WindowsMError.installFailed("Could not format the EFI partition (\(part)) for boot files.")
        }
        // eraseVolume auto-mounts; fall back to an explicit mount if needed.
        var espPath = (try? mountPoint(of: part)) ?? nil
        if espPath == nil || espPath?.isEmpty == true {
            _ = try? runUser("/usr/sbin/diskutil", ["mount", part])
            espPath = (try? mountPoint(of: part)) ?? nil
        }
        guard let esp = espPath, !esp.isEmpty else {
            throw WindowsMError.installFailed("The EFI partition (\(part)) could not be mounted to write boot files.")
        }

        let fm = FileManager.default
        let espEFI = "\(esp)/EFI"
        let espM1N1 = "\(esp)/m1n1"
        try? fm.createDirectory(atPath: espEFI, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: espM1N1, withIntermediateDirectories: true)

        // cp -R the staged contents onto the mounted ESP.
        let cpEFI = try runUser("/bin/cp", ["-R", "\(staging)/EFI/.", "\(espEFI)/"])
        let cpM1N1 = try runUser("/bin/cp", ["-R", "\(staging)/m1n1/.", "\(espM1N1)/"])
        guard cpEFI == 0, cpM1N1 == 0,
              fm.fileExists(atPath: "\(espEFI)/Microsoft/Boot/bootmgfw.efi"),
              fm.fileExists(atPath: "\(espM1N1)/boot.bin") else {
            throw WindowsMError.installFailed("Could not copy the boot files onto the EFI partition.")
        }
        // Drop macOS AppleDouble sidecars (harmless to UEFI, but keep it clean).
        _ = try? runUser("/usr/bin/find", [esp, "-name", "._*", "-delete"])
        onProgress(0.96)
        onLog("EFI partition written: EFI/Microsoft/Boot/bootmgfw.efi, EFI/BOOT/BOOTAA64.EFI, m1n1/boot.bin", .success)

        // Boot-option registration (bless) needs root + the lowered security
        // policy; it is deferred. Use the startup picker (hold power) to select
        // the disk. Unmount the ESP so it isn't left mounted.
        onStage(.configuringBoot)
        _ = try? runUser("/usr/sbin/diskutil", ["unmount", part])
        onLog("Boot files in place. To boot, hold the power button and pick the disk from the startup options.", .info)

        onProgress(1.0)
        onStage(.finished)
        onLog("Installation finished.", .success)
    }

    /// Runs a tool synchronously as this (user) process; returns exit status.
    @discardableResult
    private func runUser(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func mountPoint(of part: String) throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", part]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["MountPoint"] as? String
    }

    // MARK: - Running the job

    private let kUserCancelledStatusValue: Int32 = -128
    private var kUserCancelledStatus: Int32 { kUserCancelledStatusValue }

    /// Non-privileged direct run (dry run only).
    private func runDirect(jobPath: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [jobPath]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func runAdmin(jobPath: String) async throws -> Int32 {
        // `do shell script` with admin runs the job as root after one auth
        // prompt and blocks until it finishes, fine, we tail the log meanwhile.
        // Resolves to:  /bin/bash '<jobPath>'  run as root.
        let appleScript = "do shell script \"/bin/bash \" & quoted form of "
            + appleStringLiteral(jobPath) + " with administrator privileges"

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Output parsing

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@@ESP_STAGING ") {
            espStagingPath = String(trimmed.dropFirst("@@ESP_STAGING ".count)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("@@ESP_PART ") {
            espPartition = String(trimmed.dropFirst("@@ESP_PART ".count)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("@@STAGE ") {
            let name = String(trimmed.dropFirst("@@STAGE ".count)).trimmingCharacters(in: .whitespaces)
            if name == "failed" { return } // error surfaced via exit status + log
            if let stage = Self.stageByName[name] {
                onStage(stage)
            }
        } else if trimmed.hasPrefix("@@PROGRESS ") {
            let value = String(trimmed.dropFirst("@@PROGRESS ".count)).trimmingCharacters(in: .whitespaces)
            if let fraction = Double(value) {
                onProgress(min(max(fraction, 0), 1))
            }
        } else if !trimmed.isEmpty {
            let level: LogLevel = trimmed.hasPrefix("ERROR")   ? .error
                                : trimmed.contains("WARNING")  ? .warning
                                : trimmed.hasPrefix("Done.")   ? .success
                                : .info
            onLog(trimmed, level)
        }
    }

    // MARK: - Quoting helpers

    /// POSIX single-quote for the bash job wrapper.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal (double-quoted, backslash-escaped).
    private func appleStringLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Polls a growing log file and emits complete new lines.
private final class LogTailer {
    private let url: URL
    private let onLine: (String) -> Void
    private var offset: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var carry = ""
    private let queue = DispatchQueue(label: "com.windowsm.logtailer")

    init(url: URL, onLine: @escaping (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func drain() { queue.sync { self.poll() } }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        carry += String(decoding: data, as: UTF8.self)
        while let nl = carry.firstIndex(of: "\n") {
            let line = String(carry[carry.startIndex..<nl])
            carry.removeSubrange(carry.startIndex...nl)
            onLine(line)
        }
    }
}
