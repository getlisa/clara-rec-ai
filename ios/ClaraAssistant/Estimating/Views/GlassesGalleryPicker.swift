import Photos
import SwiftUI

/// Picks photos the technician took with the glasses' own capture button.
///
/// Those photos never reach this app through the SDK — the button press is decoded in the DAT
/// transport but never published, and there is no gallery API. They arrive instead via the Meta AI
/// app, which imports them off the glasses and files them in a "Meta AI" album in the iOS photo
/// library. That album is what this reads.
///
/// The practical shape this gives a job: walk the site pressing the glasses button, then come back
/// and pull the whole set into the estimate at once.
struct GlassesGalleryPicker: View {
    let store: QuoteStore

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PhotoLibraryImport.Candidate] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var progress = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No glasses photos found", systemImage: "eyeglasses")
                    } description: {
                        Text("Photos you take with the button on your glasses appear here once the Meta AI app has imported them. Open Meta AI to sync, then try again.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(candidates) { candidate in
                                GalleryCell(
                                    asset: candidate.asset,
                                    isSelected: selected.contains(candidate.id)
                                ) {
                                    if selected.contains(candidate.id) {
                                        selected.remove(candidate.id)
                                    } else {
                                        selected.insert(candidate.id)
                                    }
                                }
                            }
                        }
                        .padding(3)
                    }
                }
            }
            .navigationTitle("From your glasses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button(selected.isEmpty ? "Add" : "Add \(selected.count)") { importSelected() }
                            .disabled(selected.isEmpty)
                    }
                }
                ToolbarItem(placement: .status) {
                    if !progress.isEmpty {
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                candidates = await PhotoLibraryImport.glassesPhotos()
                isLoading = false
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func importSelected() {
        let chosen = candidates.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isImporting = true

        Task {
            defer { isImporting = false; progress = "" }

            var jpegs: [Data] = []
            for (index, candidate) in chosen.enumerated() {
                progress = "Reading \(index + 1) of \(chosen.count)…"
                // Full-size original, orientation baked in. May pull from iCloud, which is why
                // this reports progress rather than appearing to hang.
                if let data = await PhotoLibraryImport.jpeg(for: candidate.asset) {
                    jpegs.append(data)
                }
            }

            guard !jpegs.isEmpty else { return }
            progress = "Uploading \(jpegs.count)…"
            await store.attachPhotos(jpegs)
            dismiss()
        }
    }
}

private struct GalleryCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.35))
                        .padding(5)
                        .shadow(radius: 1)
                }
                .overlay {
                    if isSelected {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .task {
            image = await PhotoLibraryImport.thumbnail(
                for: asset, size: CGSize(width: 320, height: 320)
            )
        }
    }
}
