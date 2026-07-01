import SwiftUI

/// Container: step indicator on top, the active step below.
struct WizardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            StepIndicatorView(currentStep: state.step)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()

            // Content fills the area between the indicator and the pinned
            // footer. Each step manages its own internal scrolling (Lists
            // scroll natively; Welcome wraps its checks in a ScrollView).
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)

            Divider()
            // Pinned footer, the primary navigation button is ALWAYS visible
            // here, independent of content height or window size.
            FooterBar()
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .welcome:       WelcomeView()
        case .diskSelection: DiskSelectionView()
        case .isoSelection:  ISOSelectionView()
        case .download:      DownloadView()
        case .installation:  InstallationView()
        case .bootSetup:     BootSetupView()
        case .completion:    CompletionView()
        }
    }
}

/// Pinned bottom navigation: Back on the left, the step's primary Continue on
/// the right. Step-specific actions (Start Install, Build ISO…) live in their
/// views; this guarantees the wizard is always navigable.
struct FooterBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let cfg = state.navConfig
        HStack {
            if state.canGoBack {
                Button("Back") { state.goBack() }
                    .controlSize(.large)
            }
            Spacer()
            if cfg.showNext {
                Button(cfg.nextTitle) { state.goNext() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!cfg.nextEnabled)
            }
        }
    }
}

/// Horizontal breadcrumb of wizard steps.
struct StepIndicatorView: View {
    let currentStep: WizardStep

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WizardStep.allCases) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: step))
                        .frame(width: 10, height: 10)
                    Text(step.title)
                        .font(.callout)
                        .fontWeight(step == currentStep ? .semibold : .regular)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                }
                if step != WizardStep.allCases.last {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 1)
                        .frame(maxWidth: 36)
                }
            }
            Spacer()
        }
    }

    private func color(for step: WizardStep) -> Color {
        if step < currentStep { return .green }
        if step == currentStep { return .accentColor }
        return Color(nsColor: .quaternaryLabelColor)
    }
}

