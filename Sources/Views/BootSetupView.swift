import SwiftUI

/// Step 5: install macOS onto the stub partition, lower its Startup Security
/// in recoveryOS, register m1n1 as its boot object. The first two span
/// reboots the app can't perform, so the screen is re-entrant.
struct BootSetupView: View {
    @EnvironmentObject private var state: AppState

    private var supported: Bool { ChipSupport.bootchainSupported }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boot Setup")
                        .font(.largeTitle.bold())
                    Text("Windows is on the disk. These steps make it bootable: a minimal macOS on the stub partition carries the boot policy, and m1n1 hijacks its boot slot.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !supported {
                    unsupportedBanner
                }

                stepBox(number: 1,
                        title: "Install macOS onto “WinM Stub”",
                        done: stubReady) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run the macOS installer and choose the “WinM Stub” volume on your external disk as the destination. The Mac restarts into the install; when Setup Assistant appears, click through it minimally, then boot back into your main macOS and reopen WindowsM.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if let installer = StubBootRegistrar.macOSInstallerApp() {
                                Button("Open \(installer.deletingPathExtension().lastPathComponent)") {
                                    NSWorkspace.shared.open(installer)
                                }
                            } else {
                                Text("No macOS installer found in /Applications — fetch one with:  softwareupdate --fetch-full-installer")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Button(state.isCheckingStub ? "Checking…" : "Check Again") {
                                state.refreshStubState()
                            }
                            .disabled(state.isCheckingStub)
                        }
                        if state.stubState == .noStubPartition {
                            Label("The stub partition was not found on the selected disk — was it prepared by an older WindowsM install? Re-run the installer.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                }

                stepBox(number: 2,
                        title: "Lower Startup Security for the stub (recoveryOS)",
                        done: false) {
                    instructionList(BootchainManager.stubSecurityInstructions)
                }

                stepBox(number: 3,
                        title: "Register the Windows boot object",
                        done: state.bootRegistered) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Swaps the stub’s kernel slot for m1n1 (kmutil configure-boot). Afterwards, holding the power button at startup and picking “WinM Stub” boots Windows.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(state.isRegisteringBoot ? "Registering…" : "Register Boot Object") {
                            state.registerBootObject()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isRegisteringBoot || stubNotReady)
                        if stubNotReady {
                            Text("Complete step 1 first (no macOS system volume detected on the stub).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let command = state.recoveryOSCommand {
                            recoveryFallback(command: command)
                        }
                        if let error = state.bootSetupError {
                            Label(error, systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !state.bootSetupLog.isEmpty {
                    GroupBox("Log") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.bootSetupLog) { entry in
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(entry.level == .error ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear { state.refreshStubState() }
    }

    private var stubReady: Bool { state.stubState == .macOSInstalled }
    private var stubNotReady: Bool { !stubReady }

    // MARK: - Pieces

    private var unsupportedBanner: some View {
        GroupBox {
            Label("On this \(ChipSupport.brandString), the m1n1 bootchain does not run yet — you can complete these steps, but Windows will not boot through (see experimental/t8132-bringup).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
        }
    }

    /// kmutil refused from the running OS, show the exact 1TR command.
    private func recoveryFallback(command: String) -> some View {
        GroupBox("Finish in recoveryOS") {
            VStack(alignment: .leading, spacing: 8) {
                Text("macOS would not register the boot object from here (the stub’s policy isn’t Permissive yet, or this macOS only allows the change from recoveryOS). Boot into recoveryOS (hold power → Options), open Utilities → Terminal, and run:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy command")
                }
            }
            .padding(6)
        }
    }

    private func stepBox<Content: View>(number: Int, title: String, done: Bool,
                                        @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                        .font(.title3)
                        .foregroundStyle(done ? .green : .secondary)
                    Text(title)
                        .font(.headline)
                }
                content()
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func instructionList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
