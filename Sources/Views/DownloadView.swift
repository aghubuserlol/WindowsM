import SwiftUI

/// Step 3a, UUP dump download with per-file progress, then local ISO build.
struct DownloadView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        DownloadContentView(downloader: state.downloader)
    }
}

private struct DownloadContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var downloader: UUPDownloader
    @State private var phaseError: String?
    @State private var isPreparing = false
    @State private var isBuildingISO = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Download Windows 11 ARM64")
                    .font(.largeTitle.bold())
                Text(downloader.statusMessage)
                    .foregroundStyle(.secondary)
            }

            if let build = downloader.build {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(build.title).fontWeight(.medium)
                            Text("Build \(build.build) · \(build.arch) · ID \(build.uuid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }

            if let phaseError {
                Label(phaseError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !downloader.fileProgress.isEmpty {
                ProgressView(value: downloader.overallProgress) {
                    HStack {
                        Text("Overall")
                        Spacer()
                        Text("\(Int(downloader.overallProgress * 100))%")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }

                List(downloader.fileProgress) { file in
                    FileProgressRow(file: file)
                }
                .listStyle(.inset)
                .frame(minHeight: 160)
            } else {
                Spacer()
            }

            HStack {
                if downloader.isDownloading || downloader.isConverting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !downloader.isDownloading && !downloader.allFilesFinished {
                    Button(downloader.fileProgress.isEmpty ? "Find Latest Build" : "Start Download") {
                        downloader.fileProgress.isEmpty ? prepare() : startDownload()
                    }
                    .disabled(isPreparing)
                }
                if downloader.isDownloading {
                    Button("Cancel Downloads", role: .destructive) {
                        downloader.cancelDownloads()
                    }
                }
                if downloader.allFilesFinished && state.isoURL == nil {
                    Button("Build ISO") { buildISO() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBuildingISO)
                }
                // Reusing a cached ISO? Offer to rebuild it (keeps packages).
                if let iso = state.isoURL,
                   iso.path.hasPrefix(downloader.workDirectory.path),
                   !downloader.isConverting, !isBuildingISO {
                    Button("Rebuild ISO") {
                        downloader.discardCachedISO()
                        state.isoURL = nil
                        buildISO()
                    }
                }
            }
        }
        .onAppear {
            // Reuse a previously built ISO if one is cached, saves the whole
            // download + conversion. Kept until an install succeeds.
            if state.isoURL == nil, let cached = downloader.existingBuiltISO() {
                state.isoURL = cached
                downloader.statusMessage = "Reusing cached ISO: \(cached.lastPathComponent) — ready to install."
            } else if downloader.build == nil {
                prepare()
            }
        }
    }

    private func prepare() {
        isPreparing = true
        phaseError = nil
        Task {
            do {
                let build = try await downloader.fetchLatestBuild()
                _ = try await downloader.fetchFileList(for: build)
            } catch {
                phaseError = error.localizedDescription
            }
            isPreparing = false
        }
    }

    private func startDownload() {
        phaseError = nil
        downloader.startDownloads {
            // Files are complete; the user clicks "Build ISO" next.
        }
    }

    private func buildISO() {
        isBuildingISO = true
        phaseError = nil
        Task {
            do {
                let iso = try await downloader.convertToISO { line in
                    Task { @MainActor in state.appendLog(line, .info) }
                }
                state.isoURL = iso
            } catch {
                phaseError = error.localizedDescription
            }
            isBuildingISO = false
        }
    }
}

private struct FileProgressRow: View {
    let file: UUPDownloader.FileProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(file.entry.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusLabel
            }
            ProgressView(value: file.fraction)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch file.state {
        case .pending:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            Text(ByteCountFormatter.string(fromByteCount: file.receivedBytes, countStyle: .file))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        }
    }
}
