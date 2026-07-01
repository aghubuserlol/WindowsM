import Foundation

/// Host CLI tools the UUP download→ISO path needs. These are only required if
/// the user chooses to *download* Windows; a local ISO needs none of them.
/// The app checks them at launch, shows their status, and can install the
/// missing ones with Homebrew (a user-level operation, no admin prompt).
struct HostDependency: Identifiable {
    let id: String            // probe command, e.g. "aria2c"
    let displayName: String   // "aria2"
    let brewFormula: String?  // nil = cannot brew-install (e.g. bundled)
    let purpose: String
    /// Satisfied if ANY of these commands is on PATH (e.g. mkisofs OR genisoimage).
    let alternativeCommands: [String]
    var isInstalled: Bool = false
    var bundled: Bool = false
}

@MainActor
final class DependencyChecker: ObservableObject {

    @Published private(set) var dependencies: [HostDependency] = []
    @Published private(set) var checked = false
    @Published var isInstalling = false
    @Published var installLog: [String] = []

    /// The catalogue. wimlib-imagex ships in the bundle (injected on PATH for
    /// the converter), so it's "bundled" rather than brew-installed.
    private static func catalogue() -> [HostDependency] {
        [
            HostDependency(id: "wimlib-imagex", displayName: "wimlib",
                           brewFormula: nil,
                           purpose: "Assembles install.wim (bundled with the app)",
                           alternativeCommands: ["wimlib-imagex"]),
            // Required only for the DOWNLOAD → build-ISO path.
            HostDependency(id: "aria2c", displayName: "aria2",
                           brewFormula: "aria2",
                           purpose: "Downloads UUP packages (download path only)",
                           alternativeCommands: ["aria2c"]),
            HostDependency(id: "cabextract", displayName: "cabextract",
                           brewFormula: "cabextract",
                           purpose: "Extracts Windows update cabinets (download path only)",
                           alternativeCommands: ["cabextract"]),
            HostDependency(id: "mkisofs", displayName: "cdrtools (mkisofs)",
                           brewFormula: "cdrtools",
                           purpose: "Builds the bootable ISO (download path only)",
                           alternativeCommands: ["mkisofs", "genisoimage", "xorrisofs"]),
        ]
    }

    /// Directories to search beyond the process PATH (GUI apps inherit a thin
    /// PATH, so Homebrew locations must be probed explicitly), plus the app's
    /// bundled Resources for wimlib-imagex.
    private var searchDirectories: [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
        if let res = Bundle.main.resourceURL?.path { dirs.insert(res, at: 0) }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        return dirs
    }

    func check() {
        var deps = Self.catalogue()
        let dirs = searchDirectories
        for i in deps.indices {
            let found = deps[i].alternativeCommands.contains { cmd in
                dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(cmd)") }
            }
            deps[i].isInstalled = found
            deps[i].bundled = (deps[i].brewFormula == nil)
        }
        dependencies = deps
        checked = true
    }

    /// Required tools that are missing AND can be installed via Homebrew.
    var missingInstallable: [HostDependency] {
        dependencies.filter { !$0.isInstalled && $0.brewFormula != nil }
    }

    /// True when every required tool is present (bundled ones count as present
    /// once the file exists in Resources).
    var allSatisfied: Bool {
        checked && dependencies.allSatisfy { $0.isInstalled }
    }

    var homebrewInstalled: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Installs the missing formulae with `brew install` (runs as the user; no
    /// admin prompt). Streams output into `installLog`.
    func installMissing() {
        guard !isInstalling, let brew = brewPath else { return }
        let formulae = missingInstallable.compactMap(\.brewFormula)
        guard !formulae.isEmpty else { return }
        isInstalling = true
        installLog = ["$ brew install \(formulae.joined(separator: " "))"]

        Task {
            let status = try? await Shell.runStreaming(
                brew, ["install"] + formulae,
                environment: ProcessInfo.processInfo.environment
            ) { line in
                Task { @MainActor in self.installLog.append(line) }
            }
            await MainActor.run {
                self.installLog.append(status == 0
                    ? "✓ Done." : "✗ brew exited with status \(status ?? -1).")
                self.isInstalling = false
                self.check()
            }
        }
    }
}
