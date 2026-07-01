import Foundation

enum WindowsMError: LocalizedError {
    case notAppleSilicon
    case helperInstallFailed(String)
    case helperConnectionFailed
    case diskEnumerationFailed(String)
    case isoMountFailed(String)
    case wimNotFound(String)
    case downloadFailed(String)
    case isoConversionFailed(String)
    case resourceMissing(name: String, hint: String)
    case installFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAppleSilicon:
            return "WindowsM only runs on Apple Silicon Macs."
        case .helperInstallFailed(let reason):
            return "Could not install the privileged helper: \(reason)"
        case .helperConnectionFailed:
            return "Lost the XPC connection to the privileged helper."
        case .diskEnumerationFailed(let reason):
            return "Could not enumerate external disks: \(reason)"
        case .isoMountFailed(let reason):
            return "Could not mount the Windows ISO: \(reason)"
        case .wimNotFound(let mountPoint):
            return "No sources/install.wim (or install.esd) found in the ISO mounted at \(mountPoint). Is this a Windows 11 ARM64 ISO?"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .isoConversionFailed(let reason):
            return "Building the ISO from UUP packages failed: \(reason)"
        case .resourceMissing(let name, let hint):
            return "Bundled resource “\(name)” is missing from the app bundle. \(hint)"
        case .installFailed(let reason):
            return "Installation failed: \(reason)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

enum LogLevel: String {
    case info, warning, error, success
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let level: LogLevel
    let message: String
}
