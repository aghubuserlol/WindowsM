import Foundation

/// Mounts ISOs with hdiutil and finds the Windows install image inside.
enum ISOManager {

    struct MountedISO {
        let mountPoint: String
        let devEntry: String
    }

    /// Blocking; call from a background task.
    static func mount(isoAt url: URL) throws -> MountedISO {
        let output = try Shell.run("/usr/bin/hdiutil",
                                   ["attach", url.path, "-plist", "-nobrowse", "-readonly"])
        guard output.status == 0 else {
            throw WindowsMError.isoMountFailed(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let plist = try PropertyListSerialization.propertyList(from: output.stdout, options: [], format: nil)
        guard let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            throw WindowsMError.isoMountFailed("Unexpected hdiutil output.")
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                let dev = (entity["dev-entry"] as? String) ?? ""
                return MountedISO(mountPoint: mountPoint, devEntry: dev)
            }
        }
        throw WindowsMError.isoMountFailed("hdiutil attached the image but reported no mount point.")
    }

    static func unmount(_ iso: MountedISO) {
        _ = try? Shell.run("/usr/bin/hdiutil", ["detach", iso.mountPoint, "-force"])
    }

    /// Windows ISOs carry the image at sources/install.wim; UUP-built ISOs
    /// occasionally produce install.esd (also a WIM container, wimlib reads
    /// both).
    static func locateInstallImage(inMountPoint mountPoint: String) -> URL? {
        let candidates = [
            "sources/install.wim",
            "sources/install.esd",
            "Sources/install.wim",
            "Sources/install.esd",
        ]
        for candidate in candidates {
            let url = URL(fileURLWithPath: mountPoint).appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
