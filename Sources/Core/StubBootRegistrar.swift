import Foundation

/// Detects the state of the "WinM Stub" macOS install on the target disk and
/// runs wm-register-boot.sh (one admin prompt) to swap its kernel slot for
/// m1n1. See the README for why the stub exists.
final class StubBootRegistrar {

    enum StubState: Equatable {
        /// Not checked yet, or the check itself failed.
        case unknown
        /// s2 is missing or not an APFS container, the disk was not prepared
        /// by this version of the installer.
        case noStubPartition
        /// The APFS container exists but carries no macOS system volume.
        case awaitingMacOSInstall
        /// A macOS system volume is present, ready for the hijack.
        case macOSInstalled
    }

    enum RegistrationOutcome: Equatable {
        case registered
        /// kmutil refused (policy not Permissive, or this macOS restricts
        /// cross-volume LocalPolicy writes to recoveryOS). The payload is the
        /// exact command to run in the recoveryOS (1TR) Terminal.
        case needsRecoveryOS(command: String)
    }

    // MARK: - Detection

    /// Blocking; call off the main thread. Mounts the stub's volumes read-side
    /// as needed (user-session diskutil, no elevation).
    static func detectState(disk: DiskInfo) -> StubState {
        guard let info = try? Shell.runPlist("/usr/sbin/diskutil",
                                             ["info", "-plist", disk.stubPartition]) else {
            return .noStubPartition
        }
        guard let container = info["APFSContainerReference"] as? String, !container.isEmpty else {
            return .noStubPartition
        }
        // Look for a macOS system volume among the container's slices -
        // SystemVersion.plist only exists on a System volume, never on
        // Data/Preboot/Recovery.
        for index in 1...8 {
            let volume = "\(container)s\(index)"
            guard var volumeInfo = try? Shell.runPlist("/usr/sbin/diskutil",
                                                       ["info", "-plist", volume]) else {
                continue
            }
            var mountPoint = volumeInfo["MountPoint"] as? String ?? ""
            if mountPoint.isEmpty {
                _ = try? Shell.run("/usr/sbin/diskutil", ["mount", volume])
                volumeInfo = (try? Shell.runPlist("/usr/sbin/diskutil",
                                                  ["info", "-plist", volume])) ?? volumeInfo
                mountPoint = volumeInfo["MountPoint"] as? String ?? ""
            }
            guard !mountPoint.isEmpty else { continue }
            if FileManager.default.fileExists(
                atPath: "\(mountPoint)/System/Library/CoreServices/SystemVersion.plist") {
                return .macOSInstalled
            }
        }
        return .awaitingMacOSInstall
    }

    /// A full macOS installer app, if one is already in /Applications
    /// ("Install macOS <name>.app"), offered as a shortcut in Boot Setup.
    static func macOSInstallerApp() -> URL? {
        let applications = URL(fileURLWithPath: "/Applications")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: applications, includingPropertiesForKeys: nil)) ?? []
        return contents.first {
            $0.lastPathComponent.hasPrefix("Install macOS") && $0.pathExtension == "app"
        }
    }

    // MARK: - Registration

    var onLog: (String, LogLevel) -> Void = { _, _ in }

    /// Runs wm-register-boot.sh as root (one admin prompt, same osascript
    /// mechanism as PrivilegedInstaller). Registration takes seconds, so the
    /// log is read once after exit rather than tailed.
    func register(disk: DiskInfo, resourcesDir: URL) async throws -> RegistrationOutcome {
        let script = resourcesDir.appendingPathComponent("wm-register-boot.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw WindowsMError.resourceMissing(name: "wm-register-boot.sh",
                                                hint: "It should ship in the app bundle Resources.")
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-rb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let logURL = scratch.appendingPathComponent("register.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let jobURL = scratch.appendingPathComponent("job.sh")
        let job = """
        #!/bin/bash
        export WM_DISK=\(shellQuote(disk.bsdName))
        export WM_RESOURCES=\(shellQuote(resourcesDir.path))
        exec /bin/bash \(shellQuote(script.path)) > \(shellQuote(logURL.path)) 2>&1
        """
        try job.write(to: jobURL, atomically: true, encoding: .utf8)

        onLog("Requesting administrator authorization to register the boot object…", .info)
        let status = try await runAdmin(jobPath: jobURL.path)

        // Surface the script's log, then decide from its markers.
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        var recoveryCommand: String?
        var sawOK = false
        for line in logText.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("@@RB_OK") {
                sawOK = true
            } else if line.hasPrefix("@@RB_NEEDS_1TR ") {
                recoveryCommand = String(line.dropFirst("@@RB_NEEDS_1TR ".count))
            } else if !line.isEmpty {
                onLog(line, line.hasPrefix("ERROR") ? .error : .info)
            }
        }

        if sawOK {
            return .registered
        }
        if let recoveryCommand {
            return .needsRecoveryOS(command: recoveryCommand)
        }
        throw WindowsMError.installFailed(
            status == -128
            ? "Administrator authorization was cancelled."
            : "Boot registration failed (status \(status)). See the log above.")
    }

    // MARK: - Plumbing (mirrors PrivilegedInstaller)

    private func runAdmin(jobPath: String) async throws -> Int32 {
        let appleScript = "do shell script \"/bin/bash \" & quoted form of "
            + appleStringLiteral(jobPath) + " with administrator privileges"
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleStringLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
