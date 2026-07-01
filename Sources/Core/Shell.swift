import Foundation

/// Minimal Process wrapper for the *non-privileged* commands the app runs
/// itself (diskutil list/info, hdiutil, csrutil status, the UUP converter).
/// Anything requiring root goes through HelperClient instead.
enum Shell {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Blocking run; call from a background task.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Read fully before waiting so large outputs can't deadlock the pipe.
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Streaming run for long-lived commands (e.g. the UUP ISO converter).
    /// `onLine` is invoked off the main thread for every line of combined
    /// stdout/stderr output. Returns the exit status.
    static func runStreaming(_ executable: String,
                             _ arguments: [String],
                             currentDirectory: URL? = nil,
                             environment: [String: String]? = nil,
                             onLine: @escaping (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lineBuffer = LineBuffer(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            lineBuffer.append(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                lineBuffer.flush()
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a command and parses its stdout as a property list dictionary
    /// (diskutil/hdiutil both support -plist output).
    static func runPlist(_ executable: String, _ arguments: [String]) throws -> [String: Any] {
        let output = try run(executable, arguments)
        guard output.status == 0 else {
            throw WindowsMError.diskEnumerationFailed(output.stderrText.isEmpty ? output.stdoutText : output.stderrText)
        }
        let plist = try PropertyListSerialization.propertyList(from: output.stdout, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw WindowsMError.diskEnumerationFailed("Unexpected plist shape from \(executable)")
        }
        return dict
    }
}

/// Accumulates pipe data and emits complete lines (handles both \n and the
/// \r-rewriting progress output styles used by wimlib and aria2).
final class LineBuffer {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<index)
            buffer.removeSubrange(buffer.startIndex...index)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let remainder = buffer
        buffer = Data()
        lock.unlock()
        if !remainder.isEmpty {
            onLine(String(decoding: remainder, as: UTF8.self))
        }
    }
}
