import SwiftUI

/// Step 1, intro and requirements check (Apple Silicon, macOS version, SIP
/// status, Startup Security notice).
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to WindowsM")
                    .font(.largeTitle.bold())
                Text("Install Windows 11 ARM64 onto an external SSD and boot it natively on your Apple Silicon Mac via the m1n1 + EDK2 UEFI bootchain.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox("System check") {
                if state.requirements.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking requirements…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.requirements) { check in
                            RequirementRow(check: check)
                        }
                    }
                    .padding(8)
                }
            }

            DownloadToolsBox(checker: state.dependencies)

            Text("You will need: an external SSD (80 GB or larger, it will be erased), about 12 GB of free space for the Windows image, and an administrator password.")
                .font(.callout)
                .foregroundStyle(.secondary)
          }
        }
        .onAppear { state.loadRequirements() }
    }
}

/// Shows the host tools needed only for the *download* path, their install
/// status, and a one-click Homebrew install for the missing ones.
private struct DownloadToolsBox: View {
    @ObservedObject var checker: DependencyChecker

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Required tools", systemImage: "shippingbox")
                        .font(.headline)
                    Spacer()
                    if checker.allSatisfied {
                        Label("All installed", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.callout)
                    }
                }
                Text("These (aria2, cabextract, cdrtools) are only needed if you download Windows in the app. If you use a local ISO, installing needs none of them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(checker.dependencies) { dep in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: dep.isInstalled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(dep.isInstalled ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(dep.displayName).fontWeight(.medium)
                                if dep.bundled {
                                    Text("bundled").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.blue.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(dep.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !dep.isInstalled {
                            Text(dep.bundled ? "missing from bundle" : "not installed")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                if !checker.allSatisfied {
                    Divider()
                    if !checker.missingInstallable.isEmpty {
                        if checker.homebrewInstalled {
                            HStack {
                                Button {
                                    checker.installMissing()
                                } label: {
                                    Label(checker.isInstalling ? "Installing…" : "Install Missing Tools with Homebrew",
                                          systemImage: "arrow.down.app")
                                }
                                .disabled(checker.isInstalling)
                                if checker.isInstalling { ProgressView().controlSize(.small) }
                                Spacer()
                                Button("Re-check") { checker.check() }
                                    .disabled(checker.isInstalling)
                            }
                        } else {
                            Text("Homebrew not found. Install it from brew.sh, then run:\n  brew install \(checker.missingInstallable.compactMap(\.brewFormula).joined(separator: " "))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !checker.installLog.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(checker.installLog.suffix(80).enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(.caption2, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: 110)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct RequirementRow: View {
    let check: RequirementCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).fontWeight(.medium)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch check.status {
        case .passed:  return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var symbolColor: Color {
        switch check.status {
        case .passed:  return .green
        case .warning: return .orange
        case .failed:  return .red
        case .info:    return .blue
        }
    }
}
