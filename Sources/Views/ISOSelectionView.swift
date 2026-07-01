import SwiftUI
import UniformTypeIdentifiers

/// Step 3, choose between downloading a fresh build via UUP dump or using a
/// local Windows 11 ARM64 ISO.
struct ISOSelectionView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Windows installation image")
                    .font(.largeTitle.bold())
                Text("WindowsM needs a Windows 11 ARM64 image (install.wim inside an ISO).")
                    .foregroundStyle(.secondary)
            }

            ForEach(ISOSource.allCases) { source in
                SourceCard(source: source,
                           isSelected: state.isoSource == source,
                           selectedISO: source == .localFile ? state.isoURL : nil)
                    .onTapGesture {
                        state.isoSource = source
                        if source == .localFile && state.isoURL == nil {
                            showingImporter = true
                        }
                    }
            }

            if state.isoSource == .localFile {
                HStack {
                    Button("Choose ISO…") { showingImporter = true }
                    if let url = state.isoURL {
                        Text(url.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let importError {
                    Label(importError, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 0)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.pathExtension.lowercased() == "iso" {
                    state.isoURL = url
                    importError = nil
                } else {
                    importError = "Please choose a .iso file."
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.diskImage]
        if let iso = UTType(filenameExtension: "iso") {
            types.insert(iso, at: 0)
        }
        return types
    }
}

private struct SourceCard: View {
    let source: ISOSource
    let isSelected: Bool
    let selectedISO: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source == .download ? "arrow.down.circle.fill" : "opticaldisc.fill")
                .font(.title)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title).font(.headline)
                Text(source.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let selectedISO {
                    Text(selectedISO.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}
