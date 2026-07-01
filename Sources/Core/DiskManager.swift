import Foundation
import DiskArbitration

/// Discovers external physical disks. Enumeration comes from
/// `diskutil list -plist external physical`; per-disk details are merged from
/// `diskutil info -plist` and a DiskArbitration description, which has the
/// nicer media/model names. Partitioning itself happens in the root helper.
enum DiskManager {

    /// Blocking; call via Task.detached / a background executor.
    static func externalPhysicalDisks() throws -> [DiskInfo] {
        let list = try Shell.runPlist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard let wholeDisks = list["WholeDisks"] as? [String] else { return [] }
        return wholeDisks.compactMap { try? details(forBSDName: $0) }
            .sorted { $0.bsdName < $1.bsdName }
    }

    static func details(forBSDName bsdName: String) throws -> DiskInfo {
        let info = try Shell.runPlist("/usr/sbin/diskutil", ["info", "-plist", bsdName])
        let daDescription = diskArbitrationDescription(bsdName: bsdName)

        let mediaName = (daDescription?[kDADiskDescriptionMediaNameKey as String] as? String)
            ?? (info["MediaName"] as? String)
            ?? bsdName
        let size = (info["TotalSize"] as? Int64)
            ?? (info["Size"] as? Int64)
            ?? Int64((daDescription?[kDADiskDescriptionMediaSizeKey as String] as? Int) ?? 0)
        let busProtocol = (daDescription?[kDADiskDescriptionDeviceProtocolKey as String] as? String)
            ?? (info["BusProtocol"] as? String)
            ?? "Unknown"

        return DiskInfo(
            bsdName: bsdName,
            mediaName: mediaName,
            totalSizeBytes: size,
            busProtocol: busProtocol,
            isRemovable: (info["RemovableMedia"] as? Bool) ?? (info["Removable"] as? Bool) ?? false,
            isSolidState: (info["SolidState"] as? Bool) ?? false
        )
    }

    private static func diskArbitrationDescription(bsdName: String) -> [String: Any]? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return nil
        }
        return DADiskCopyDescription(disk) as? [String: Any]
    }
}
