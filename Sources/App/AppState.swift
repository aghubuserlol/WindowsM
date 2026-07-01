import SwiftUI

enum ISOSource: String, CaseIterable, Identifiable {
    case download
    case localFile

    var id: String { rawValue }
    var title: String {
        switch self {
        case .download:  return "Download Windows 11 ARM64 (UUP dump)"
        case .localFile: return "Use a local ISO file"
        }
    }
    var subtitle: String {
        switch self {
        case .download:  return "Fetches the latest build from Microsoft's servers and assembles a bootable ISO on this Mac."
        case .localFile: return "Pick a Windows 11 ARM64 ISO you already have."
        }
    }
}

/// Single source of truth for the wizard. All mutation happens on the main
/// actor; long-running work is delegated to Core types.
@MainActor
final class AppState: ObservableObject {

    // Navigation
    @Published var step: WizardStep = .welcome

    // Step 1, Welcome
    @Published var requirements: [RequirementCheck] = []
    @Published var requirementsLoaded = false

    // Step 2, Disk selection
    @Published var disks: [DiskInfo] = []
    @Published var isLoadingDisks = false
    @Published var diskError: String?
    @Published var selectedDisk: DiskInfo?
    @Published var eraseConfirmed = false

    // Step 3, ISO selection
    @Published var isoSource: ISOSource = .download
    @Published var isoURL: URL?
    @Published var imageIndex = 1

    // Step 4, Installation
    @Published var stage: InstallStage = .idle
    @Published var overallProgress: Double = 0
    @Published var logEntries: [LogEntry] = []
    @Published var installError: String?
    @Published var isInstalling = false

    let downloader = UUPDownloader()
    let dependencies = DependencyChecker()

    private var installTask: Task<Void, Never>?

    // MARK: - Navigation

    var canGoBack: Bool {
        // bootSetup and completion sit after a finished (destructive) install;
        // there is nothing meaningful to go back to.
        step != .welcome && !isInstalling && step != .bootSetup && step != .completion
    }

    func goNext() {
        switch step {
        case .welcome:       step = .diskSelection
        case .diskSelection: step = .isoSelection
        case .isoSelection:  step = isoSource == .download ? .download : .installation
        case .download:      step = .installation
        case .installation:  step = .bootSetup; refreshStubState()
        case .bootSetup:     step = .completion
        case .completion:    break
        }
    }

    func goBack() {
        switch step {
        case .welcome:       break
        case .diskSelection: step = .welcome
        case .isoSelection:  step = .diskSelection
        case .download:      step = .isoSelection
        case .installation:  step = isoSource == .download ? .download : .isoSelection
        case .bootSetup:     break
        case .completion:    break
        }
    }

    /// Drives the pinned footer in WizardView so the primary action button is
    /// ALWAYS visible regardless of window size (the old per-view button could
    /// be pushed off the bottom edge).
    struct NavConfig {
        var showNext: Bool
        var nextTitle: String
        var nextEnabled: Bool
    }

    var navConfig: NavConfig {
        switch step {
        case .welcome:
            return NavConfig(showNext: true, nextTitle: "Continue",
                             nextEnabled: requirementsLoaded && !hasBlockingRequirementFailure)
        case .diskSelection:
            return NavConfig(showNext: true, nextTitle: "Continue",
                             nextEnabled: selectedDisk != nil && eraseConfirmed)
        case .isoSelection:
            return NavConfig(showNext: true, nextTitle: "Continue",
                             nextEnabled: isoSource == .download || isoURL != nil)
        case .download:
            return NavConfig(showNext: true, nextTitle: "Continue to Install",
                             nextEnabled: isoURL != nil)
        case .installation:
            // The primary action (Start / Dry Run / Cancel) lives in the view.
            return NavConfig(showNext: false, nextTitle: "", nextEnabled: false)
        case .bootSetup:
            // Registration is optional to proceed, the stub steps span a
            // reboot, so users may finish them later and relaunch.
            return NavConfig(showNext: true, nextTitle: "Continue", nextEnabled: !isRegisteringBoot)
        case .completion:
            return NavConfig(showNext: false, nextTitle: "", nextEnabled: false)
        }
    }

    // MARK: - Welcome

    func loadRequirements() {
        dependencies.check()   // host tools for the download path
        guard !requirementsLoaded else { return }
        Task {
            requirements = await RequirementsChecker.runAll()
            requirementsLoaded = true
        }
    }

    var hasBlockingRequirementFailure: Bool {
        requirements.contains { $0.status == .failed }
    }

    // MARK: - Disks

    func refreshDisks() {
        isLoadingDisks = true
        diskError = nil
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try DiskManager.externalPhysicalDisks()
                }.value
                disks = found
                if let selected = selectedDisk, !found.contains(selected) {
                    selectedDisk = nil
                    eraseConfirmed = false
                }
            } catch {
                diskError = error.localizedDescription
                disks = []
            }
            isLoadingDisks = false
        }
    }

    // MARK: - Installation

    /// When true, the next install runs the script in dry-run mode: it walks
    /// every stage and logs exactly what it would do, but erases nothing. Lets
    /// you exercise the whole flow (and the admin prompt) before committing a
    /// disk.
    @Published var dryRun = false

    func startInstallation() {
        guard !isInstalling, let disk = selectedDisk, let iso = isoURL else { return }
        guard let resources = Bundle.main.resourceURL else {
            installError = "Could not locate the app bundle resources."
            return
        }
        isInstalling = true
        installError = nil
        overallProgress = 0
        stage = .idle
        logEntries = []
        appendLog(dryRun
                  ? "Dry run: simulating install of Windows 11 ARM64 onto \(disk.mediaName) (\(disk.deviceNode)). Nothing will be erased."
                  : "Installing Windows 11 ARM64 onto \(disk.mediaName) (\(disk.deviceNode)). This ERASES the disk.",
                  .info)

        // Real, working path on an unsigned local build: one admin prompt,
        // then the bundled wm-install.sh runs every privileged step as root.
        let installer = PrivilegedInstaller()
        installer.onStage = { [weak self] stage in
            Task { @MainActor in self?.stage = stage }
        }
        installer.onProgress = { [weak self] progress in
            Task { @MainActor in self?.overallProgress = progress }
        }
        installer.onLog = { [weak self] message, level in
            Task { @MainActor in self?.appendLog(message, level) }
        }

        let config = PrivilegedInstaller.Configuration(
            disk: disk, isoURL: iso, resourcesDir: resources,
            imageIndex: imageIndex, dryRun: dryRun)
        installTask = Task {
            do {
                try await installer.install(config)
                isInstalling = false
                stage = .finished
                overallProgress = 1
                // Success: reclaim the cached UUP packages + built ISO. They
                // were kept across attempts so a retry never re-downloads or
                // re-converts; now that it worked, free the space. (A local
                // ISO lives outside the cache and is untouched.)
                downloader.cleanupAfterSuccessfulInstall()
                appendLog("Install succeeded — cleared cached build files.", .info)
                goNext() // → completion
            } catch is CancellationError {
                installError = WindowsMError.cancelled.localizedDescription
                appendLog("Installation cancelled.", .warning)
                isInstalling = false
                stage = .idle
            } catch {
                installError = error.localizedDescription
                appendLog(error.localizedDescription, .error)
                isInstalling = false
            }
        }
    }

    /// Cancellation is best-effort: stage boundaries check for cancellation,
    /// but an in-flight wimlib apply inside the helper runs to completion.
    func cancelInstallation() {
        installTask?.cancel()
    }

    // MARK: - Boot Setup (macOS stub hijack)

    @Published var stubState: StubBootRegistrar.StubState = .unknown
    @Published var isCheckingStub = false
    @Published var isRegisteringBoot = false
    @Published var bootRegistered = false
    /// Set when kmutil refused from the running OS, the exact command to run
    /// in the recoveryOS (1TR) Terminal instead.
    @Published var recoveryOSCommand: String?
    @Published var bootSetupError: String?
    @Published var bootSetupLog: [LogEntry] = []

    func refreshStubState() {
        guard let disk = selectedDisk, !isCheckingStub else { return }
        isCheckingStub = true
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                StubBootRegistrar.detectState(disk: disk)
            }.value
            stubState = state
            isCheckingStub = false
        }
    }

    func registerBootObject() {
        guard let disk = selectedDisk, !isRegisteringBoot else { return }
        guard let resources = Bundle.main.resourceURL else {
            bootSetupError = "Could not locate the app bundle resources."
            return
        }
        isRegisteringBoot = true
        bootSetupError = nil
        recoveryOSCommand = nil

        let registrar = StubBootRegistrar()
        registrar.onLog = { [weak self] message, level in
            Task { @MainActor in self?.bootSetupLog.append(LogEntry(level: level, message: message)) }
        }
        Task {
            do {
                switch try await registrar.register(disk: disk, resourcesDir: resources) {
                case .registered:
                    bootRegistered = true
                    bootSetupLog.append(LogEntry(level: .success,
                        message: "Boot object registered — pick “WinM Stub” from the startup picker to boot Windows."))
                case .needsRecoveryOS(let command):
                    recoveryOSCommand = command
                }
            } catch {
                bootSetupError = error.localizedDescription
            }
            isRegisteringBoot = false
        }
    }

    func appendLog(_ message: String, _ level: LogLevel = .info) {
        logEntries.append(LogEntry(level: level, message: message))
    }
}
