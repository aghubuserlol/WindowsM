import Foundation

struct RequirementCheck: Identifiable {
    enum Status {
        case passed
        case warning
        case failed
        case info
    }

    let id = UUID()
    let name: String
    let detail: String
    let status: Status
}

/// Pre-flight checks shown on the Welcome screen.
enum RequirementsChecker {

    static func runAll() async -> [RequirementCheck] {
        var checks: [RequirementCheck] = []
        checks.append(appleSiliconCheck())
        checks.append(macOSVersionCheck())
        checks.append(await sipCheck())
        checks.append(startupSecurityNotice())
        return checks
    }

    private static func appleSiliconCheck() -> RequirementCheck {
        var isARM64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &isARM64, &size, nil, 0)
        return RequirementCheck(
            name: "Apple Silicon",
            detail: isARM64 == 1 ? "Running on an Apple Silicon Mac." : "This Mac is not Apple Silicon — Windows 11 ARM64 cannot boot here.",
            status: isARM64 == 1 ? .passed : .failed
        )
    }

    private static func macOSVersionCheck() -> RequirementCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let supported = version.majorVersion >= 14
        return RequirementCheck(
            name: "macOS 14 or later",
            detail: "Running macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion).",
            status: supported ? .passed : .failed
        )
    }

    /// SIP does not have to be disabled for this flow (boot security is a
    /// separate, per-OS policy on Apple Silicon), surfaced as information.
    private static func sipCheck() async -> RequirementCheck {
        let detail: String
        if let output = try? Shell.run("/usr/bin/csrutil", ["status"]) {
            detail = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            detail = "Could not query csrutil."
        }
        return RequirementCheck(
            name: "System Integrity Protection",
            detail: detail + " SIP does not need to be changed for this installer.",
            status: .info
        )
    }

    /// Apple restriction: lowering Startup Security to permit booting
    /// third-party kernels can ONLY be done by a human in recoveryOS
    /// (Startup Security Utility / bputil). The app guides; it cannot do it.
    private static func startupSecurityNotice() -> RequirementCheck {
        RequirementCheck(
            name: "Startup Security (manual step)",
            detail: "Before first boot of Windows you must set Startup Security to “No Security” in recoveryOS: shut down, hold the power button, Options → Utilities → Startup Security Utility. WindowsM will remind you at the end.",
            status: .warning
        )
    }
}
