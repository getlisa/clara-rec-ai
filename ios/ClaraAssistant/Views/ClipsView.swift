import AVKit
import Photos
import SwiftUI

struct ClipsView: View {
    @State private var store = RecordingsStore()
    @State private var selected: PHAsset?

    var body: some View {
        Group {
            if store.needsPermission {
                ContentUnavailableView(
                    "Photos access needed",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("Clara-Assistant saves recordings to your photo library. Allow access in Settings to browse them here.")
                )
            } else if store.assets.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "video.slash",
                    description: Text("Recordings you make from the live view appear here, and in the \(PhotoLibrarySaver.albumName) album in Photos.")
                )
            } else {
                List {
                    ForEach(store.assets, id: \.localIdentifier) { asset in
                        Button {
                            selected = asset
                        } label: {
                            ClipRow(asset: asset, store: store)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await store.delete(asset) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { await store.reload() }
        .refreshable { await store.reload() }
        .sheet(item: $selected) { asset in
            ClipPlayerView(asset: asset, store: store)
        }
    }
}

private struct ClipRow: View {
    let asset: PHAsset
    let store: RecordingsStore

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "video").foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 56)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.creationDate.map(Self.dateFormatter.string) ?? "Unknown date")
                    .font(.subheadline.weight(.medium))
                Text("\(Self.duration(asset.duration))  ·  \(asset.pixelWidth)×\(asset.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "play.circle").foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .task {
            thumbnail = await store.thumbnail(for: asset, size: CGSize(width: 252, height: 168))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ClipPlayerView: View {
    let asset: PHAsset
    let store: RecordingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if let item = await store.playerItem(for: asset) {
                player = AVPlayer(playerItem: item)
            }
        }
        .onDisappear { player?.pause() }
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}
