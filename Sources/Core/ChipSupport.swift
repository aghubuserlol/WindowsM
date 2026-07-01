import Foundation

/// Determines the Apple Silicon generation and whether the m1n1 + UEFI
/// bootchain can actually boot this machine today.
///
/// Support reality (mirrors experimental/t8132-bringup): the chain works on
/// M1 and M2 families (t8103 / t8112 / t600x / t602x). M3 (t8122 / t603x) and
/// M4 (t8132 / t604x) are NOT bootable yet, m1n1's per-core bring-up for those
/// SoCs is unfinished upstream. The installer still writes a correct disk on
/// any Apple Silicon Mac; this just lets the UI tell the truth about booting.
enum ChipSupport {

    enum Generation: String {
        case m1 = "M1"
        case m2 = "M2"
        case m3 = "M3"
        case m4 = "M4"
        case unknown = "Apple Silicon"
    }

    /// Marketing name, e.g. "Apple M4 Pro".
    static var brandString: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var generation: Generation {
        let brand = brandString
        if brand.contains("M1") { return .m1 }
        if brand.contains("M2") { return .m2 }
        if brand.contains("M3") { return .m3 }
        if brand.contains("M4") { return .m4 }
        return .unknown
    }

    enum SupportTier {
        /// Chain is known to boot (verified on real hardware).
        case supported
        /// Bring-up assets exist and the attempt is safe, but no boot has been
        /// confirmed on this SoC yet. The user can try and help prove it.
        case experimental
        /// No bring-up work exists for this SoC in this repo.
        case unsupported
    }

    static var tier: SupportTier {
        switch generation {
        case .m1, .m2:    return .supported
        case .m4:         return .experimental   // scaffold in experimental/t8132-bringup
        case .m3:         return .unsupported     // no t8122 assets in this repo yet
        case .unknown:    return .unsupported
        }
    }

    /// True when the chain is known-good. Kept for call sites that only care
    /// about the verified case.
    static var bootchainSupported: Bool { tier == .supported }

    /// True when the user can attempt the boot (supported or experimental).
    /// Gates whether the flow offers to proceed at all.
    static var bootchainAttemptable: Bool { tier != .unsupported }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
