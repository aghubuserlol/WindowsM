import Foundation

/// App-side wrapper around the bootchain stages performed by the root helper,
/// plus the instruction text for the manual recoveryOS steps.
///
/// Boot path after install: iBoot -> m1n1 stage 1 (the stub's boot slot) ->
/// chainload -> ESP m1n1/boot.bin (stage 2) -> Windows Boot Manager.
enum BootchainManager {

    /// Writes m1n1+EDK2 to the mounted ESP and stages drivers/BCD.
    /// BCD template and drivers are optional, missing ones are skipped with
    /// a warning rather than failing the install.
    static func installBootchain(efiMountPoint: String) async throws {
        let m1n1 = try BundledResources.require(BundledResources.m1n1,
                                                name: "m1n1.bin",
                                                producedBy: "scripts/build-m1n1.sh")
        let edk2 = try BundledResources.require(BundledResources.edk2,
                                                name: "edk2-apple.fd",
                                                producedBy: "scripts/build-edk2.sh")
        try await HelperClient.shared.installBootchain(
            m1n1Path: m1n1.path,
            edk2Path: edk2.path,
            bcdTemplatePath: BundledResources.bcdTemplate?.path ?? "",
            driversPath: BundledResources.driversDirectory?.path ?? "",
            efiMountPoint: efiMountPoint
        )
    }

    /// Registers the external disk as a boot option (best effort, see
    /// HelperProtocol.configureStartupBootOption).
    static func configureStartupBootOption(efiPartition: String) async throws {
        try await HelperClient.shared.configureStartupBootOption(efiPartitionBSDName: efiPartition)
    }

    /// Hijacks the "WinM Stub" macOS install's boot slot with m1n1 (signed
    /// helper path; the working ad-hoc path is StubBootRegistrar).
    static func registerStubBootObject(disk: DiskInfo) async throws {
        let m1n1 = try BundledResources.require(BundledResources.m1n1,
                                                name: "m1n1.bin",
                                                producedBy: "scripts/build-m1n1.sh")
        try await HelperClient.shared.registerStubBootObject(bsdName: disk.bsdName,
                                                             m1n1Path: m1n1.path)
    }

    /// The manual recoveryOS procedure for the STUB volume. Apple restricts
    /// boot-policy changes to physical presence in recoveryOS; no app or
    /// daemon can perform them. Note the policy being lowered belongs to the
    /// throwaway "WinM Stub" install on the external SSD, the internal
    /// disk's policy stays Full Security.
    static let stubSecurityInstructions: [String] = [
        "Shut down your Mac completely.",
        "Press and HOLD the power button until “Loading startup options…” appears.",
        "Select Options, then click Continue to enter recoveryOS.",
        "Open Utilities → Startup Security Utility from the menu bar.",
        "Select the “WinM Stub” disk (NOT your internal macOS disk) and click “Security Policy…”.",
        "Choose “Permissive Security” (the wording varies by macOS version). Your internal disk’s security is untouched.",
        "Restart back into your main macOS and return to this screen.",
    ]

    /// Kept for the completion screen: the same steps, since the completion
    /// view summarizes what Boot Setup walked through.
    static var startupSecurityInstructions: [String] { stubSecurityInstructions }

    /// Post-registration summary shown on the completion screen. The actual
    /// registration is automated in the Boot Setup step (kmutil configure-boot
    /// against the stub, the Asahi Linux mechanism); these lines only explain
    /// the result.
    static let bootObjectRegistrationInstructions: [String] = [
        "The Boot Setup step registered m1n1 as the “WinM Stub” install’s boot object (the same kmutil mechanism the Asahi Linux installer uses).",
        "Apple’s startup picker lists the stub because it is a real, personalized macOS install. Picking “WinM Stub” (hold power at startup) now boots the Windows chain instead of macOS.",
        "If you skipped Boot Setup or it asked you to finish in recoveryOS, relaunch WindowsM and return to that step. The disk itself is complete.",
    ]
}
