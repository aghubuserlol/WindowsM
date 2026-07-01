import SwiftUI

/// Step 5, success state. The post-install guidance is chip-aware: M1/M2 can
/// actually boot the chain (with the manual recoveryOS steps); M3/M4 cannot
/// yet, so we say so honestly instead of implying a reboot will work.
struct CompletionView: View {
    @EnvironmentObject private var state: AppState

    private var supported: Bool { ChipSupport.bootchainSupported }
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

            if supported {
                supportedGuidance
            } else {
                unsupportedGuidance
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

    // MARK: - M3 / M4 (not bootable yet, be honest)

    @ViewBuilder
    private var unsupportedGuidance: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("This \(chip) can’t boot the install yet", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("The disk is built correctly — Windows, the EFI boot files, and the m1n1 + UEFI payload are all in place, and the Boot Setup stub steps will register cleanly. But the m1n1 bootloader does not support M3/M4 silicon yet, so picking “WinM Stub” at startup will hang at the m1n1 stage rather than reach Windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This isn’t something the install did wrong — it’s the edge of what’s possible on this chip today (see experimental/t8132-bringup).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }

        GroupBox("What you can do") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("Keep the disk as-is — it’s ready for the day M3/M4 bootchain support lands upstream.")
                bullet("To run Windows on this Mac today, use a VM (UTM is free; Parallels or VMware Fusion also run Windows 11 ARM64 well).")
                bullet("Have an M1 or M2 Mac? The bootchain genuinely works there — run the installer on that machine.")
                bullet("Please don’t lower Startup Security expecting a Windows boot here — on M3/M4 it won’t boot through, so it’s effort without payoff.")
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
