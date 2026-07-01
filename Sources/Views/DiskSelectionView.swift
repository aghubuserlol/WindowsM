import SwiftUI

/// Step 2, pick the external SSD that will be erased for Windows.
struct DiskSelectionView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose the target disk")
                        .font(.largeTitle.bold())
                    Text("Only external physical disks are shown. The selected disk will be completely erased.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.refreshDisks()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.isLoadingDisks)
            }

            if let error = state.diskError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            Group {
                if state.isLoadingDisks {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning for external disks…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.disks.isEmpty {
                    ContentUnavailableView("No external disks found",
                                           systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Connect an external SSD (USB or Thunderbolt) and click Refresh."))
                } else {
                    List(state.disks, selection: selectionBinding) { disk in
                        DiskRow(disk: disk)
                            .tag(disk)
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 200)
                }
            }
            .frame(maxHeight: .infinity)

            if let disk = state.selectedDisk {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Everything on “\(disk.mediaName)” (\(disk.sizeDescription), \(disk.deviceNode)) will be permanently erased.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if !disk.isLargeEnoughForWindows {
                            Label("This disk is smaller than 80 GB — Windows 11 plus the macOS boot stub will not fit comfortably.",
                                  systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                        Toggle("I understand that all data on this disk will be destroyed.",
                               isOn: $state.eraseConfirmed)
                    }
                    .padding(6)
                }
            }
        }
        .onAppear {
            if state.disks.isEmpty { state.refreshDisks() }
        }
    }

    private var selectionBinding: Binding<DiskInfo?> {
        Binding(
            get: { state.selectedDisk },
            set: { newValue in
                state.selectedDisk = newValue
                state.eraseConfirmed = false
            }
        )
    }
}

private struct DiskRow: View {
    let disk: DiskInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.mediaName).fontWeight(.medium)
                Text("\(disk.deviceNode) · \(disk.sizeDescription) · \(disk.busProtocol)\(disk.isSolidState ? " · SSD" : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !disk.isLargeEnoughForWindows {
                Text("Too small")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
