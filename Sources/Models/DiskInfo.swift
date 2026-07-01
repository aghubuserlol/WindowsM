import Foundation

/// An external physical disk eligible as a Windows target.
struct DiskInfo: Identifiable, Hashable {
    /// BSD name without the /dev prefix, e.g. "disk4".
    let bsdName: String
    /// Human-readable media name, e.g. "Samsung Portable SSD T7 Media".
    let mediaName: String
    let totalSizeBytes: Int64
    /// e.g. "USB", "Thunderbolt"
    let busProtocol: String
    let isRemovable: Bool
    let isSolidState: Bool

    var id: String { bsdName }
    var deviceNode: String { "/dev/\(bsdName)" }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    /// Windows needs roughly 25 GB and the macOS stub partition takes 32 GB;
    /// we require headroom on top of both.
    var isLargeEnoughForWindows: Bool {
        totalSizeBytes >= 80 * 1_000_000_000
    }

    /// Partition slices after `partitionDiskForWindows` has run.
    /// diskutil reserves s1 as the EFI System Partition on GPT disks; s2 is
    /// the APFS "WinM Stub" container whose macOS install carries the
    /// LocalPolicy that boots the chain (see wm-register-boot.sh).
    var efiPartition: String { "\(bsdName)s1" }
    var stubPartition: String { "\(bsdName)s2" }
    var msrPartition: String { "\(bsdName)s3" }
    var windowsPartition: String { "\(bsdName)s4" }
}
