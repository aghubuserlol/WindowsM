//
//  HelperProtocol.swift
//  Shared between the WindowsM app and the privileged helper.
//
//  The app never elevates itself: every root operation crosses this XPC
//  boundary into com.windowsm.helper, installed via SMJobBless.
//

import Foundation

public enum HelperConstants {
    /// Mach service name. Must match the helper's launchd Label, its bundle
    /// identifier, and the key in the app's SMPrivilegedExecutables dict.
    public static let machServiceName = "com.windowsm.helper"

    /// Bumped whenever the protocol or helper behavior changes; the app
    /// re-blesses the helper when versions disagree.
    public static let version = "1.1.0"
}

/// Exported by the *app* on its side of the connection so the helper can
/// stream log lines and progress back during long operations (wimlib apply
/// can run for many minutes).
@objc public protocol HelperProgressProtocol {
    func helperDidEmitLog(_ line: String)
    /// `stage` is a free-form identifier (e.g. "apply"), `percent` is 0...100.
    func helperDidUpdateProgress(stage: String, percent: Double)
}

/// Exported by the helper. All paths are absolute. Every call replies with an
/// NSError on failure (domain "com.windowsm.helper") or nil on success.
@objc public protocol HelperProtocol {

    /// Protocol/health check. Replies with HelperConstants.version.
    func version(reply: @escaping (String) -> Void)

    /// Erases `bsdName` (e.g. "disk4") with a GPT layout for Windows:
    ///   s1  EFI System Partition (FAT32, created automatically by diskutil)
    ///   s2  APFS "WinM Stub"     (holds the throwaway macOS whose LocalPolicy
    ///                            boots the chain, see registerStubBootObject)
    ///   s3  Microsoft Reserved   (retyped via gpt(8), best effort)
    ///   s4  WINDOWS              (formatted NTFS with the bundled mkntfs)
    /// Refuses to touch internal disks.
    func partitionDiskForWindows(bsdName: String,
                                 mkntfsPath: String,
                                 reply: @escaping (NSError?) -> Void)

    /// Applies image `imageIndex` of `wimPath` directly onto the NTFS
    /// partition (e.g. "disk4s3") using wimlib's NTFS-3G mode. This bypasses
    /// macOS's read-only NTFS support entirely, wimlib writes the volume
    /// through libntfs-3g, the partition stays unmounted.
    func applyWindowsImage(wimlibPath: String,
                           wimPath: String,
                           imageIndex: Int,
                           ntfsPartitionBSDName: String,
                           reply: @escaping (NSError?) -> Void)

    /// Extracts \Windows\Boot\EFI from the WIM and lays out the EFI System
    /// Partition: EFI/Microsoft/Boot/* plus EFI/BOOT/BOOTAA64.EFI fallback.
    func extractBootFiles(wimlibPath: String,
                          wimPath: String,
                          imageIndex: Int,
                          efiMountPoint: String,
                          reply: @escaping (NSError?) -> Void)

    /// Mounts a partition (e.g. "disk4s1") and replies with its mount point.
    func mountPartition(bsdName: String,
                        reply: @escaping (String?, NSError?) -> Void)

    /// Unmounts a whole disk or a single partition (best effort, forced).
    func unmount(bsdName: String, reply: @escaping (NSError?) -> Void)

    /// Writes the m1n1 + EDK2 chain onto the mounted ESP:
    ///   m1n1/boot.bin       = m1n1.bin with edk2 firmware appended as payload
    ///   EFI/Microsoft/Boot/BCD  = template BCD (if provided, may be empty "")
    ///   drivers/            = bundled Windows drivers (if provided, may be "")
    func installBootchain(m1n1Path: String,
                          edk2Path: String,
                          bcdTemplatePath: String,
                          driversPath: String,
                          efiMountPoint: String,
                          reply: @escaping (NSError?) -> Void)

    /// Best-effort `bless --setBoot` for the external disk. On Apple Silicon
    /// this only succeeds once Startup Security has been lowered in
    /// recoveryOS; failure is reported but should be treated as a warning -
    /// the user can always pick the disk from the startup picker (hold power).
    func configureStartupBootOption(efiPartitionBSDName: String,
                                    reply: @escaping (NSError?) -> Void)

    /// Hijacks the "WinM Stub" macOS install on `bsdName`'s s2 so it boots the
    /// Windows chain: assembles m1n1 stage 1 (m1n1.bin + a chainload variable
    /// pointing at the ESP's m1n1/boot.bin) and registers it with
    /// `kmutil configure-boot`, the Asahi Linux mechanism. Requires the stub
    /// volume's Startup Security to be Permissive already (recoveryOS step);
    /// the error message carries the recoveryOS fallback command otherwise.
    func registerStubBootObject(bsdName: String,
                                m1n1Path: String,
                                reply: @escaping (NSError?) -> Void)

    /// Removes the helper's launchd job and binary (used by an uninstaller).
    func uninstallHelper(reply: @escaping (NSError?) -> Void)
}
