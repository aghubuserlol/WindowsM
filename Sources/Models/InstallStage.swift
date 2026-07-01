import Foundation

/// Sequential stages of the install pipeline, used to drive the progress UI.
enum InstallStage: Int, CaseIterable, Equatable {
    case idle
    case installingHelper
    case mountingISO
    case partitioning
    case applyingImage
    case extractingBootFiles
    case installingBootchain
    case configuringBoot
    case finished

    var title: String {
        switch self {
        case .idle:                return "Waiting to start"
        case .installingHelper:    return "Installing privileged helper"
        case .mountingISO:         return "Mounting Windows ISO"
        case .partitioning:        return "Partitioning disk (GPT: EFI + macOS stub + MSR + NTFS)"
        case .applyingImage:       return "Applying Windows image (wimlib)"
        case .extractingBootFiles: return "Copying EFI boot files"
        case .installingBootchain: return "Installing m1n1 + EDK2 bootchain"
        case .configuringBoot:     return "Configuring startup boot option"
        case .finished:            return "Finished"
        }
    }

    /// Stages shown as rows in InstallationView. Excludes idle/finished and
    /// installingHelper, the working (admin-script) install path performs the
    /// privileged steps directly after one authorization, with no blessed
    /// helper to install.
    static var visibleStages: [InstallStage] {
        allCases.filter { $0 != .idle && $0 != .finished && $0 != .installingHelper }
    }

    /// Fraction of the overall progress bar this stage begins at.
    /// `applyingImage` dominates wall-clock time, so it gets most of the bar.
    var progressSpan: (start: Double, end: Double) {
        switch self {
        case .idle:                return (0.00, 0.00)
        case .installingHelper:    return (0.00, 0.03)
        case .mountingISO:         return (0.03, 0.06)
        case .partitioning:        return (0.06, 0.14)
        case .applyingImage:       return (0.14, 0.82)
        case .extractingBootFiles: return (0.82, 0.90)
        case .installingBootchain: return (0.90, 0.96)
        case .configuringBoot:     return (0.96, 1.00)
        case .finished:            return (1.00, 1.00)
        }
    }
}
