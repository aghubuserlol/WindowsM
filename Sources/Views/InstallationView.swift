import SwiftUI

/// Step 4, live log + progress bar across every install stage.
struct InstallationView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install Windows")
                    .font(.largeTitle.bold())
                summaryLine
            }

            ProgressView(value: state.overallProgress) {
                HStack {
                    Text(state.stage.title)
                    Spacer()
                    Text("\(Int(state.overallProgress * 100))%").monospacedDigit()
                }
                .font(.callout)
            }

            HStack(alignment: .top, spacing: 16) {
                stageList
                    .frame(width: 280)
                logView
            }
            .frame(maxHeight: .infinity)

            if let error = state.installError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                if !state.isInstalling && state.stage != .finished {
                    Toggle("Dry run (don’t erase — simulate only)", isOn: $state.dryRun)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if state.isInstalling {
                    Button("Cancel", role: .destructive) { state.cancelInstallation() }
                } else if state.stage != .finished {
                    Button(buttonTitle) { state.startInstallation() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(state.dryRun ? .accentColor : .red)
                        .disabled(state.selectedDisk == nil || state.isoURL == nil)
                }
            }
        }
    }

    private var buttonTitle: String {
        if state.installError != nil { return state.dryRun ? "Retry Dry Run" : "Retry Installation" }
        return state.dryRun ? "Start Dry Run" : "Erase Disk & Install Windows"
    }

    private var summaryLine: some View {
        let disk = state.selectedDisk.map { "\($0.mediaName) (\($0.deviceNode))" } ?? "no disk selected"
        let iso = state.isoURL?.lastPathComponent ?? "no image selected"
        return Text("Target: \(disk) · Image: \(iso)")
            .foregroundStyle(.secondary)
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(InstallStage.visibleStages, id: \.rawValue) { stage in
                HStack(spacing: 8) {
                    stageIcon(for: stage)
                    Text(stage.title)
                        .font(.callout)
                        .foregroundStyle(stage == state.stage ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func stageIcon(for stage: InstallStage) -> some View {
        if stage.rawValue < state.stage.rawValue || state.stage == .finished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if stage == state.stage && state.isInstalling {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else if stage == state.stage && state.installError != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.logEntries) { entry in
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: state.logEntries.count) { _, _ in
                if let last = state.logEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info:    return .primary
        case .warning: return .orange
        case .error:   return .red
        case .success: return .green
        }
    }
}
