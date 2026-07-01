import Foundation

/// Locates binaries and data files that ship inside the app bundle.
/// None of these are committed to the repo, they are produced by the
/// scripts/ directory and dropped into Sources/Resources before archiving.
enum BundledResources {

    /// wimlib's CLI, built statically with NTFS-3G support (scripts/build-wimlib.sh).
    static var wimlibImagex: URL? { locate("wimlib-imagex") }

    /// mkntfs from ntfs-3g, used to format the Windows partition (same script).
    static var mkntfs: URL? { locate("mkntfs") }

    /// m1n1 stage binary (scripts/build-m1n1.sh).
    static var m1n1: URL? { locate("m1n1.bin") }

    /// EDK2 UEFI firmware image for Apple Silicon (scripts/build-edk2.sh).
    static var edk2: URL? { locate("edk2-apple.fd") }

    /// Optional template BCD store copied to the ESP. Building a BCD hive
    /// from scratch on macOS is out of scope; see README "BCD template".
    static var bcdTemplate: URL? { locate("BCD") }

    /// UUP dump converter script directory (scripts/fetch-uup-converter.sh).
    static var uupConverterScript: URL? { locate("uup-converter/convert.sh") }

    /// Bundled Apple Silicon Windows drivers, staged onto the ESP for
    /// installation inside Windows (scripts/fetch-drivers.sh).
    static var driversDirectory: URL? { locate("drivers") }

    private static func locate(_ relativePath: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Throws a descriptive error when a required resource is absent, naming
    /// the script that produces it.
    static func require(_ url: URL?, name: String, producedBy script: String) throws -> URL {
        guard let url else {
            throw WindowsMError.resourceMissing(name: name, hint: "Build it with \(script) and re-build the app.")
        }
        return url
    }
}
