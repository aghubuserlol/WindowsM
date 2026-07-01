import Foundation

/// The wizard's screens, in order.
enum WizardStep: Int, CaseIterable, Comparable, Identifiable {
    case welcome
    case diskSelection
    case isoSelection
    case download      // step 3a — skipped when the user picks a local ISO
    case installation
    case bootSetup     // macOS stub + boot-object registration (the hijack)
    case completion

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:       return "Welcome"
        case .diskSelection: return "Disk"
        case .isoSelection:  return "Windows Image"
        case .download:      return "Download"
        case .installation:  return "Install"
        case .bootSetup:     return "Boot Setup"
        case .completion:    return "Done"
        }
    }

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
