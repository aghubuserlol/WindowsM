import SwiftUI

/// Step 5, success state. Guidance is chip-aware: M1/M2 boot the chain with
/// the manual recoveryOS steps; M4 can be attempted (experimental, unverified);
/// M3 and unknown chips have no bring-up assets, so say so.
struct CompletionView: View {
    @EnvironmentObject private var state: AppState

    private var tier: ChipSupport.SupportTier { ChipSupport.tier }
    private var chip: String { ChipSupport.brandString }

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Windows is installed")
                        .font(.largeTitle.bold())
                    if let disk = state.selectedDisk {
                        Text("Windows 11 ARM64 was deployed to \(disk.mediaName) (\(disk.deviceNode)).")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch tier {
            case .supported:    supportedGuidance
            case .experimental: experimentalGuidance
            case .unsupported:  unsupportedGuidance
            }

            HStack {
                Spacer()
                Button("Quit WindowsM") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
          }
          .padding(.bottom, 8)
        }
    }

    // MARK: - M1 / M2 (can boot, with manual steps)

    @ViewBuilder
    private var supportedGuidance: some View {
        GroupBox("If you skipped it — Startup Security for the stub (recoveryOS)") {
            instructionList(BootchainManager.startupSecurityInstructions)
        }

        GroupBox("How booting works now") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Experimental", systemImage: "flask")
                    .font(.caption).foregroundStyle(.orange)
                instructionList(BootchainManager.bootObjectRegistrationInstructions, numbered: false)
            }
            .padding(8)
        }

        GroupBox("Switching between Windows and macOS") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Boot Windows: hold the power button, pick “WinM Stub”.", systemImage: "power")
                Label("Return to macOS: hold the power button, pick Macintosh HD.", systemImage: "apple.logo")
            }
            .font(.callout)
            .padding(8)
        }
    }

    // MARK: - M4 (attemptable, unverified)

    @ViewBuilder
    private var experimentalGuidance: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Experimental on this \(chip)", systemImage: "flask.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("The disk is built correctly and you can attempt the boot, but the m1n1 bring-up for this chip has never booted on real hardware. Expect it to hang at the m1n1 stage. Trying is safe: the boot object is on the external SSD and is only entered when you pick it from the startup picker, your internal macOS is untouched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("To actually get it booting you'll need a UART/USB debug cable and a second Mac to run the m1n1 proxy. See experimental/t8132-bringup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }

        GroupBox("Manual step, Startup Security for the stub (recoveryOS)") {
            instructionList(BootchainManager.startupSecurityInstructions)
        }

        GroupBox("Switching between Windows and macOS") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Try Windows: hold the power button, pick “WinM Stub”.", systemImage: "power")
                Label("Return to macOS: hold the power button, pick Macintosh HD.", systemImage: "apple.logo")
            }
            .font(.callout)
            .padding(8)
        }
    }

    // MARK: - M3 / unknown (no bring-up assets, be honest)

    @ViewBuilder
    private var unsupportedGuidance: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("This \(chip) can’t boot the install yet", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("The disk is built correctly and the Boot Setup stub steps will register cleanly. But there are no m1n1 bring-up assets for this chip in this repo, so picking “WinM Stub” at startup will hang at the m1n1 stage. Making it boot means building a device tree from this machine's hardware first (the M4 work in experimental/t8132-bringup is the template).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }

        GroupBox("What you can do") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("Keep the disk as-is, it's ready once bring-up for this chip exists.")
                bullet("To run Windows on this Mac today, use a VM (UTM is free; Parallels and VMware Fusion also run Windows 11 ARM64).")
                bullet("Have an M1 or M2 Mac? The bootchain genuinely works there, run the installer on that machine.")
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private func instructionList(_ lines: [String], numbered: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
