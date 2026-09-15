import AVFoundation
import Photos
import SwiftUI

/// Lists the recordings the app saved, read back from its Photos album.
@MainActor
@Observable
final class RecordingsStore {

    private(set) var assets: [PHAsset] = []
    private(set) var needsPermission = false

    func reload() async {
        guard await PhotoLibrarySaver.requestAccess() else {
            needsPermission = true
            assets = []
            return
        }
        needsPermission = false

        guard let album = PhotoLibrarySaver.existingAlbum() else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(in: album, options: options)
        var found: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in found.append(asset) }
        assets = found
    }

    func delete(_ asset: PHAsset) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            await reload()
        } catch {
            // Deletion shows a system confirmation; a cancel lands here and needs no handling.
        }
    }

    func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery calls back more than once; resume only on the final one.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
