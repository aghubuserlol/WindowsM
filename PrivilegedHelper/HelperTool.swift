//
//  HelperTool.swift
//  com.windowsm.helper
//
//  Implements every privileged operation. One instance per XPC connection.
//
//  Safety posture:
//   * partitioning refuses internal disks and validates BSD names against a
//     strict pattern, nothing here ever touches the boot disk.
//   * binaries handed over from the app (wimlib-imagex, mkntfs) live inside
//     the signed app bundle; TODO(release): verify their code signatures /
//     hashes here before executing them as root.
//

import Foundation

final class HelperTool: NSObject, HelperProtocol {

    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    // MARK: - Progress plumbing

    private var progressProxy: HelperProgressProtocol? {
        connection?.remoteObjectProxy as? HelperProgressProtocol
    }

    private func log(_ line: String) {
        NSLog("com.windowsm.helper: %@", line)
        progressProxy?.helperDidEmitLog(line)
    }

    private func progress(_ stage: String, _ percent: Double) {
        progressProxy?.helperDidUpdateProgress(stage: stage, percent: percent)
    }

    private func fail(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "com.windowsm.helper", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - HelperProtocol

    func version(reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    func partitionDiskForWindows(bsdName: String,
                                 mkntfsPath: String,
                                 reply: @escaping (NSError?) -> Void) {
        do {
            let disk = try validatedWholeDisk(bsdName)

            // Hard refusal for internal disks, the m1n1 stub on the internal
            // APFS container is handled separately and never via partitioning.
            let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", disk])
            if (info["Internal"] as? Bool) ?? true {
                throw fail(10, "\(disk) is an internal disk; refusing to partition it.")
            }

            log("Erasing \(disk) with GPT layout for Windows…")
            progress("partition", 5)

            // diskutil automatically reserves slice 1 as a true EFI System
            // Partition (FAT32, type C12A7328…) on GPT whole-disk erases, so
            // the explicit layout below declares the stub placeholder + MSR +
            // Windows. The auto ESP is ~200 MB (Windows defaults to 100 MB).
            // Slice 2 starts as plain ExFAT and becomes the APFS "WinM Stub"
            // container AFTER the gpt retype, gpt(8) needs the physical disk
            // quiescent, and an active APFS container would hold it busy.
            let result = try run("/usr/sbin/diskutil",
                                 ["partitionDisk", "/dev/\(disk)", "GPT",
                                  "ExFAT", "STUB", "32G",
                                  "ExFAT", "MSR", "128M",
                                  "ExFAT", "WINDOWS", "R"]) { [weak self] line in
                self?.log(line)
            }
            guard result.status == 0 else {
                throw fail(11, "diskutil partitionDisk failed: \(result.output.suffix(400))")
            }
            progress("partition", 40)

            // Best effort: retype slice 3 from Microsoft Basic Data to
            // Microsoft Reserved. Windows boots without this; setup tools are
            // just happier when an MSR exists with the right GUID.
            retypeMSRPartition(disk: disk, sliceIndex: 3)
            progress("partition", 50)

            // Convert the stub placeholder into the APFS "WinM Stub"
            // container. The user later installs a minimal macOS there whose
            // LocalPolicy is what lets iBoot chainload m1n1 (see
            // registerStubBootObject).
            let apfs = try run("/usr/sbin/diskutil",
                               ["apfs", "create", "/dev/\(disk)s2", "WinM Stub"]) { [weak self] line in
                self?.log(line)
            }
            guard apfs.status == 0 else {
                throw fail(13, "diskutil apfs create failed for \(disk)s2: \(apfs.output.suffix(400))")
            }
            progress("partition", 60)

            // Format the Windows slice NTFS with the bundled mkntfs -
            // macOS has no native NTFS formatter. The slice must be unmounted.
            let windowsSlice = "\(disk)s4"
            _ = try? run("/usr/sbin/diskutil", ["unmount", "force", windowsSlice], lineHandler: nil)
            log("Formatting \(windowsSlice) as NTFS…")
            let mkntfs = try run(mkntfsPath, ["-f", "-F", "-L", "WINDOWS", "/dev/\(windowsSlice)"]) { [weak self] line in
                self?.log(line)
            }
            guard mkntfs.status == 0 else {
                throw fail(12, "mkntfs failed (\(mkntfs.status)): \(mkntfs.output.suffix(400))")
            }
            progress("partition", 100)
            log("Partitioning complete: \(disk)s1 ESP, \(disk)s2 APFS stub, \(disk)s3 MSR, \(disk)s4 NTFS.")
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func applyWindowsImage(wimlibPath: String,
                           wimPath: String,
                           imageIndex: Int,
                           ntfsPartitionBSDName: String,
                           reply: @escaping (NSError?) -> Void) {
        do {
            let slice = try validatedSlice(ntfsPartitionBSDName)
            // The slice must not be mounted: wimlib opens the block device and
            // writes the NTFS volume itself through libntfs-3g. This is what
            // lets us deploy onto NTFS despite macOS being read-only on NTFS.
            _ = try? run("/usr/sbin/diskutil", ["unmount", "force", slice], lineHandler: nil)

            log("Applying image \(imageIndex) of \(URL(fileURLWithPath: wimPath).lastPathComponent) to /dev/\(slice) (this is the long stage)…")
            let result = try run(wimlibPath,
                                 ["apply", wimPath, String(imageIndex), "/dev/\(slice)"]) { [weak self] line in
                self?.log(line)
                // wimlib progress lines look like:
                //   "Applying image 1 ... 1234 MiB of 9876 MiB (12%) done"
                if let percent = Self.parsePercent(from: line) {
                    self?.progress("apply", percent)
                }
            }
            guard result.status == 0 else {
                throw fail(20, "wimlib-imagex apply failed (\(result.status)): \(result.output.suffix(400))")
            }
            progress("apply", 100)
            log("Image applied.")
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func extractBootFiles(wimlibPath: String,
                          wimPath: String,
                          imageIndex: Int,
                          efiMountPoint: String,
                          reply: @escaping (NSError?) -> Void) {
        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: efiMountPoint) else {
                throw fail(30, "ESP mount point \(efiMountPoint) does not exist.")
            }

            let microsoftBoot = "\(efiMountPoint)/EFI/Microsoft/Boot"
            let fallbackBoot = "\(efiMountPoint)/EFI/BOOT"
            try fm.createDirectory(atPath: microsoftBoot, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: fallbackBoot, withIntermediateDirectories: true)

            // Pull \Windows\Boot\EFI (bootmgfw.efi + companions) out of the
            // WIM straight onto the FAT32 ESP, which macOS writes natively.
            let staging = "\(efiMountPoint)/.windowsm-staging"
            try? fm.removeItem(atPath: staging)
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: staging) }

            log("Extracting Windows boot files from the WIM…")
            let result = try run(wimlibPath,
                                 ["extract", wimPath, String(imageIndex),
                                  "/Windows/Boot/EFI",
                                  "--dest-dir=\(staging)",
                                  "--no-acls"]) { [weak self] line in
                self?.log(line)
            }
            guard result.status == 0 else {
                throw fail(31, "wimlib-imagex extract failed (\(result.status)): \(result.output.suffix(400))")
            }

            // wimlib drops the extracted tree at <staging>/EFI (basename of
            // the requested path). Copy its contents into EFI/Microsoft/Boot.
            let extractedDir = "\(staging)/EFI"
            guard fm.fileExists(atPath: extractedDir) else {
                throw fail(32, "Extraction finished but \(extractedDir) is missing.")
            }
            for item in try fm.contentsOfDirectory(atPath: extractedDir) {
                let src = "\(extractedDir)/\(item)"
                let dst = "\(microsoftBoot)/\(item)"
                try? fm.removeItem(atPath: dst)
                try fm.copyItem(atPath: src, toPath: dst)
            }

            // EDK2's BDS falls back to \EFI\BOOT\BOOTAA64.EFI when no BCD
            // boot entry resolves, so mirror bootmgfw.efi there.
            let bootmgfw = "\(microsoftBoot)/bootmgfw.efi"
            guard fm.fileExists(atPath: bootmgfw) else {
                throw fail(33, "bootmgfw.efi was not present in the WIM's /Windows/Boot/EFI.")
            }
            let fallback = "\(fallbackBoot)/BOOTAA64.EFI"
            try? fm.removeItem(atPath: fallback)
            try fm.copyItem(atPath: bootmgfw, toPath: fallback)

            log("Boot files installed: EFI/Microsoft/Boot + EFI/BOOT/BOOTAA64.EFI.")
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func mountPartition(bsdName: String, reply: @escaping (String?, NSError?) -> Void) {
        do {
            let slice = try validatedSlice(bsdName)
            let mountResult = try run("/usr/sbin/diskutil", ["mount", slice]) { [weak self] line in
                self?.log(line)
            }
            guard mountResult.status == 0 else {
                throw fail(40, "diskutil mount \(slice) failed: \(mountResult.output.suffix(300))")
            }
            let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", slice])
            guard let mountPoint = info["MountPoint"] as? String, !mountPoint.isEmpty else {
                throw fail(41, "\(slice) mounted but diskutil reports no mount point.")
            }
            reply(mountPoint, nil)
        } catch let error as NSError {
            reply(nil, error)
        }
    }

    func unmount(bsdName: String, reply: @escaping (NSError?) -> Void) {
        do {
            let name = try validatedDiskOrSlice(bsdName)
            let verb = name.contains("s") ? "unmount" : "unmountDisk"
            _ = try? run("/usr/sbin/diskutil", [verb, "force", name], lineHandler: nil)
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func installBootchain(m1n1Path: String,
                          edk2Path: String,
                          bcdTemplatePath: String,
                          driversPath: String,
                          efiMountPoint: String,
                          reply: @escaping (NSError?) -> Void) {
        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: efiMountPoint) else {
                throw fail(50, "ESP mount point \(efiMountPoint) does not exist.")
            }

            // m1n1 chainloading: payloads are appended directly after the
            // m1n1 image. Concatenating the EDK2 firmware produces a single
            // boot object, iBoot loads the m1n1 stub from the internal disk,
            // which chainloads this file from the ESP, which starts UEFI.
            log("Assembling m1n1 + EDK2 boot object…")
            let m1n1Data = try Data(contentsOf: URL(fileURLWithPath: m1n1Path))
            let edk2Data = try Data(contentsOf: URL(fileURLWithPath: edk2Path))
            var bootObject = m1n1Data
            bootObject.append(edk2Data)

            let m1n1Dir = "\(efiMountPoint)/m1n1"
            try fm.createDirectory(atPath: m1n1Dir, withIntermediateDirectories: true)
            let bootBin = "\(m1n1Dir)/boot.bin"
            try? fm.removeItem(atPath: bootBin)
            try bootObject.write(to: URL(fileURLWithPath: bootBin))
            log("Wrote \(bootBin) (\(bootObject.count) bytes).")

            // Optional BCD template. A real BCD is a registry hive that must
            // reference the target partition's GUIDs; the bundled template is
            // a best-effort starting point (see README "BCD template") and
            // Windows setup/bcdboot regenerates it on first successful boot.
            if !bcdTemplatePath.isEmpty, fm.fileExists(atPath: bcdTemplatePath) {
                let bcdDst = "\(efiMountPoint)/EFI/Microsoft/Boot/BCD"
                try fm.createDirectory(atPath: "\(efiMountPoint)/EFI/Microsoft/Boot",
                                       withIntermediateDirectories: true)
                try? fm.removeItem(atPath: bcdDst)
                try fm.copyItem(atPath: bcdTemplatePath, toPath: bcdDst)
                log("Installed BCD template.")
            } else {
                log("No BCD template bundled — Windows boot manager will need a BCD before first boot (see README).")
            }

            // Stage bundled drivers on the ESP so they are reachable from
            // within Windows (installed there via pnputil on first login).
            if !driversPath.isEmpty, fm.fileExists(atPath: driversPath) {
                let driversDst = "\(efiMountPoint)/drivers"
                try? fm.removeItem(atPath: driversDst)
                try fm.copyItem(atPath: driversPath, toPath: driversDst)
                log("Staged Apple Silicon Windows drivers at \(driversDst).")
            }

            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func configureStartupBootOption(efiPartitionBSDName: String,
                                    reply: @escaping (NSError?) -> Void) {
        do {
            let slice = try validatedSlice(efiPartitionBSDName)
            let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", slice])
            guard let mountPoint = info["MountPoint"] as? String, !mountPoint.isEmpty else {
                throw fail(60, "ESP \(slice) is not mounted; mount it before configuring boot.")
            }
            // On Apple Silicon, bless can only set a non-Apple boot object as
            // the startup choice once the security policy allows it (the
            // recoveryOS step). Until then this fails cleanly and the user
            // boots Windows from the startup picker instead.
            log("Registering boot option via bless…")
            let result = try run("/usr/sbin/bless",
                                 ["--mount", mountPoint, "--setBoot"]) { [weak self] line in
                self?.log(line)
            }
            guard result.status == 0 else {
                throw fail(61, "bless --setBoot failed (\(result.status)): \(result.output.suffix(300)). Lower Startup Security in recoveryOS first, or use the startup picker (hold power).")
            }
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func registerStubBootObject(bsdName: String,
                                m1n1Path: String,
                                reply: @escaping (NSError?) -> Void) {
        do {
            let disk = try validatedWholeDisk(bsdName)
            let info = try runPlist("/usr/sbin/diskutil", ["info", "-plist", disk])
            if (info["Internal"] as? Bool) ?? true {
                throw fail(70, "\(disk) is an internal disk; refusing.")
            }
            guard FileManager.default.fileExists(atPath: m1n1Path) else {
                throw fail(71, "m1n1.bin not found at \(m1n1Path).")
            }

            // 1. The stub's APFS container and its macOS system volume.
            let stubInfo = try runPlist("/usr/sbin/diskutil", ["info", "-plist", "\(disk)s2"])
            guard let container = stubInfo["APFSContainerReference"] as? String, !container.isEmpty else {
                throw fail(72, "\(disk)s2 is not an APFS physical store — was the disk prepared by WindowsM?")
            }
            var stubVolume: String?
            for index in 1...8 {
                let volume = "\(container)s\(index)"
                guard var volumeInfo = try? runPlist("/usr/sbin/diskutil", ["info", "-plist", volume]) else {
                    continue
                }
                var mountPoint = volumeInfo["MountPoint"] as? String ?? ""
                if mountPoint.isEmpty {
                    _ = try? run("/usr/sbin/diskutil", ["mount", volume], lineHandler: nil)
                    volumeInfo = (try? runPlist("/usr/sbin/diskutil", ["info", "-plist", volume])) ?? volumeInfo
                    mountPoint = volumeInfo["MountPoint"] as? String ?? ""
                }
                guard !mountPoint.isEmpty else { continue }
                if FileManager.default.fileExists(
                    atPath: "\(mountPoint)/System/Library/CoreServices/SystemVersion.plist") {
                    stubVolume = mountPoint
                    break
                }
            }
            guard let stubVolume else {
                throw fail(73, "No macOS system volume on \(disk)s2 — install macOS onto “WinM Stub” first.")
            }
            log("Stub macOS volume: \(stubVolume)")

            // 2. ESP partition UUID for the chainload hop to stage 2.
            let espInfo = try runPlist("/usr/sbin/diskutil", ["info", "-plist", "\(disk)s1"])
            guard let espUUID = espInfo["DiskUUID"] as? String, !espUUID.isEmpty else {
                throw fail(74, "Could not read the partition UUID of \(disk)s1.")
            }

            // 3. Assemble stage 1: m1n1.bin + chainload config variable. Kept
            //    in /Users/Shared so the recoveryOS fallback can reach it.
            let stageDir = "/Users/Shared/WindowsM"
            let stage1 = "\(stageDir)/m1n1-stage1.bin"
            try FileManager.default.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
            var stage1Data = try Data(contentsOf: URL(fileURLWithPath: m1n1Path))
            stage1Data.append(Data("chainload=\(espUUID);m1n1/boot.bin\n".utf8))
            try stage1Data.write(to: URL(fileURLWithPath: stage1))
            log("Stage 1 assembled: \(stage1) (\(stage1Data.count) bytes, chainload → ESP m1n1/boot.bin).")

            // 4. Register it. Entry point 0x800 (2048) is m1n1's raw-image
            //    entry, per m1n1's docs and the Asahi installer.
            log("Registering boot object via kmutil configure-boot…")
            let result = try run("/usr/bin/kmutil",
                                 ["configure-boot", "-c", stage1,
                                  "--raw", "--entry-point", "2048",
                                  "--lowest-virtual-address", "0",
                                  "-v", stubVolume]) { [weak self] line in
                self?.log(line)
            }
            guard result.status == 0 else {
                throw fail(75, """
                kmutil configure-boot failed (\(result.status)): \(result.output.suffix(300)). \
                Usually the stub's Startup Security is not Permissive yet, or this macOS only \
                allows the change from recoveryOS. From the recoveryOS Terminal run: \
                kmutil configure-boot -c '/Volumes/Macintosh HD - Data/Users/Shared/WindowsM/m1n1-stage1.bin' \
                --raw --entry-point 2048 --lowest-virtual-address 0 -v '/Volumes/WinM Stub'
                """)
            }
            log("Boot object registered — pick “WinM Stub” from the startup picker to boot Windows.")
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    func uninstallHelper(reply: @escaping (NSError?) -> Void) {
        log("Uninstalling helper…")
        _ = try? run("/bin/launchctl", ["remove", HelperConstants.machServiceName], lineHandler: nil)
        try? FileManager.default.removeItem(atPath: "/Library/LaunchDaemons/\(HelperConstants.machServiceName).plist")
        try? FileManager.default.removeItem(atPath: "/Library/PrivilegedHelperTools/\(HelperConstants.machServiceName)")
        reply(nil)
        exit(0)
    }

    // MARK: - GPT surgery

    /// Retypes a slice to Microsoft Reserved (E3C9E316-…) using gpt(8):
    /// read the slice's start/size, remove it, re-add it in place with the
    /// MSR type GUID. Best effort, failures are logged, never fatal.
    private func retypeMSRPartition(disk: String, sliceIndex: Int) {
        let msrGUID = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
        do {
            _ = try? run("/usr/sbin/diskutil", ["unmountDisk", "force", disk], lineHandler: nil)
            let show = try run("/usr/sbin/gpt", ["-r", "show", disk], lineHandler: nil)
            guard show.status == 0 else {
                log("gpt show failed; leaving MSR as Basic Data (harmless).")
                return
            }
            // Rows: "  start  size  index  contents"
            var start: String?
            var size: String?
            for line in show.output.split(separator: "\n") {
                let columns = line.split(separator: " ").map(String.init)
                if columns.count >= 4, columns[2] == String(sliceIndex), line.contains("GPT part") {
                    start = columns[0]
                    size = columns[1]
                    break
                }
            }
            guard let start, let size else {
                log("Could not locate slice \(sliceIndex) in the GPT; leaving MSR as Basic Data.")
                return
            }
            guard try run("/usr/sbin/gpt", ["remove", "-i", String(sliceIndex), disk], lineHandler: nil).status == 0,
                  try run("/usr/sbin/gpt", ["add", "-i", String(sliceIndex), "-b", start, "-s", size, "-t", msrGUID, disk], lineHandler: nil).status == 0 else {
                log("gpt retype of slice \(sliceIndex) failed; leaving MSR as Basic Data (harmless).")
                return
            }
            log("Slice \(sliceIndex) retyped to Microsoft Reserved.")
        } catch {
            log("MSR retype skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Validation

    /// "disk4", whole disks only.
    private func validatedWholeDisk(_ name: String) throws -> String {
        guard name.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
            throw fail(1, "“\(name)” is not a whole-disk BSD name (expected e.g. disk4).")
        }
        return name
    }

    /// "disk4s3", a partition slice.
    private func validatedSlice(_ name: String) throws -> String {
        guard name.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil else {
            throw fail(2, "“\(name)” is not a partition BSD name (expected e.g. disk4s3).")
        }
        return name
    }

    private func validatedDiskOrSlice(_ name: String) throws -> String {
        guard name.range(of: #"^disk\d+(s\d+)?$"#, options: .regularExpression) != nil else {
            throw fail(3, "“\(name)” is not a BSD disk name.")
        }
        return name
    }

    // MARK: - Process execution

    private struct RunResult {
        let status: Int32
        let output: String
    }

    /// Runs a command as root, streaming combined stdout/stderr line-by-line
    /// (handles wimlib's \r progress rewrites) and collecting full output.
    @discardableResult
    private func run(_ executable: String,
                     _ arguments: [String],
                     lineHandler: ((String) -> Void)?) throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw fail(4, "\(executable) is missing or not executable.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var collected = ""
        let lock = NSLock()
        var buffer = Data()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if !lineData.isEmpty {
                    lines.append(String(decoding: lineData, as: UTF8.self))
                }
            }
            collected += lines.map { $0 + "\n" }.joined()
            lock.unlock()
            lines.forEach { lineHandler?($0) }
        }

        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        // Drain whatever is left after termination.
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let tail = String(decoding: rest, as: UTF8.self)
            lock.lock()
            collected += tail
            lock.unlock()
            tail.split(whereSeparator: \.isNewline).forEach { lineHandler?(String($0)) }
        }

        lock.lock()
        let output = collected
        lock.unlock()
        return RunResult(status: process.terminationStatus, output: output)
    }

    private func runPlist(_ executable: String, _ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw fail(5, "\(executable) \(arguments.joined(separator: " ")) did not return a plist.")
        }
        return dict
    }

    /// Extracts "(NN%)" / "NN%" style progress from a tool output line.
    static func parsePercent(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})\s*%"#, options: .regularExpression) else {
            return nil
        }
        let digits = line[range].filter(\.isNumber)
        guard let value = Double(digits), value <= 100 else { return nil }
        return value
    }
}
