import Foundation

/// Orchestrates the full install sequence. Pure logic, UI state lives in
/// AppState, root operations live in the helper. Every stage transition and
/// log line is reported through the callbacks (invoked on arbitrary threads;
/// AppState hops them onto the main actor).
final class WindowsInstaller {

    struct Configuration {
        let disk: DiskInfo
        let isoURL: URL
        /// Index inside install.wim. UUP "professional" ISOs are single-image
        /// (index 1); multi-edition retail ISOs vary.
        let imageIndex: Int
    }

    var onStage: (InstallStage) -> Void = { _ in }
    var onLog: (String, LogLevel) -> Void = { _, _ in }
    /// Overall 0...1 across all stages.
    var onProgress: (Double) -> Void = { _ in }

    private let helper = HelperClient.shared

    func install(_ config: Configuration) async throws {
        // Wire helper streaming into our callbacks for the duration.
        helper.onLog = { [onLog] line in onLog(line, .info) }
        helper.onProgress = { [weak self] stage, percent in
            self?.stageProgress(percent / 100.0)
        }
        defer {
            helper.onLog = nil
            helper.onProgress = nil
        }

        // Stage 0: privileged helper.
        try advance(to: .installingHelper)
        try await helper.ensureHelperInstalled()
        onLog("Privileged helper ready (v\(HelperConstants.version)).", .success)

        // Stage 1: mount the ISO and find the install image.
        try advance(to: .mountingISO)
        let iso = try await Task.detached(priority: .userInitiated) {
            try ISOManager.mount(isoAt: config.isoURL)
        }.value
        onLog("Mounted \(config.isoURL.lastPathComponent) at \(iso.mountPoint).", .info)
        defer {
            ISOManager.unmount(iso)
            onLog("Unmounted ISO.", .info)
        }
        guard let wim = ISOManager.locateInstallImage(inMountPoint: iso.mountPoint) else {
            throw WindowsMError.wimNotFound(iso.mountPoint)
        }
        onLog("Install image: \(wim.path)", .info)

        // Stage 2: partition the target disk (GPT: ESP + MSR + NTFS).
        try advance(to: .partitioning)
        let mkntfs = try BundledResources.require(BundledResources.mkntfs,
                                                  name: "mkntfs",
                                                  producedBy: "scripts/build-wimlib.sh")
        try await helper.partitionDiskForWindows(bsdName: config.disk.bsdName,
                                                 mkntfsPath: mkntfs.path)
        onLog("Partitioned \(config.disk.deviceNode): \(config.disk.efiPartition) (ESP), \(config.disk.msrPartition) (MSR), \(config.disk.windowsPartition) (NTFS).", .success)

        // Stage 3: apply the Windows image straight onto the NTFS partition.
        // wimlib writes through libntfs-3g, sidestepping macOS's read-only
        // NTFS driver; the partition is never mounted by macOS.
        try advance(to: .applyingImage)
        let wimlib = try BundledResources.require(BundledResources.wimlibImagex,
                                                  name: "wimlib-imagex",
                                                  producedBy: "scripts/build-wimlib.sh")
        try await helper.applyWindowsImage(wimlibPath: wimlib.path,
                                           wimPath: wim.path,
                                           imageIndex: config.imageIndex,
                                           ntfsPartitionBSDName: config.disk.windowsPartition)
        onLog("Windows image applied to \(config.disk.windowsPartition).", .success)

        // Stage 4: populate the ESP with the Windows boot files from the WIM.
        try advance(to: .extractingBootFiles)
        let espMountPoint = try await helper.mountPartition(bsdName: config.disk.efiPartition)
        onLog("ESP mounted at \(espMountPoint).", .info)
        try await helper.extractBootFiles(wimlibPath: wimlib.path,
                                          wimPath: wim.path,
                                          imageIndex: config.imageIndex,
                                          efiMountPoint: espMountPoint)
        onLog("EFI boot files in place (EFI/Microsoft/Boot, EFI/BOOT/BOOTAA64.EFI).", .success)

        // Stage 5: m1n1 + EDK2 onto the ESP.
        try advance(to: .installingBootchain)
        try await BootchainManager.installBootchain(efiMountPoint: espMountPoint)
        onLog("m1n1 + EDK2 bootchain written to the ESP.", .success)

        // Stage 6: register the boot option. Failures here are expected until
        // Startup Security has been lowered in recoveryOS, so warn-and-continue.
        try advance(to: .configuringBoot)
        do {
            try await BootchainManager.configureStartupBootOption(efiPartition: config.disk.efiPartition)
            onLog("Startup boot option registered via bless.", .success)
        } catch {
            onLog("Could not register a boot option (\(error.localizedDescription)). This is normal before Startup Security is lowered — use the startup picker (hold power) instead.", .warning)
        }

        _ = try? await helper.unmount(bsdName: config.disk.efiPartition)

        onStage(.finished)
        onProgress(1.0)
        onLog("Installation finished. Follow the Startup Security steps to boot Windows.", .success)
    }

    // MARK: - Progress bookkeeping

    private var currentStage: InstallStage = .idle

    private func advance(to stage: InstallStage) throws {
        try Task.checkCancellation()
        currentStage = stage
        onStage(stage)
        onProgress(stage.progressSpan.start)
    }

    /// Maps a 0...1 fraction within the current stage onto the overall bar.
    private func stageProgress(_ fraction: Double) {
        let span = currentStage.progressSpan
        onProgress(span.start + (span.end - span.start) * min(max(fraction, 0), 1))
    }
}
