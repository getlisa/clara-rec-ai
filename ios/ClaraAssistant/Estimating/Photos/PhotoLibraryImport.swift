import ImageIO
import Photos
import UIKit

/// Finding photos the technician took with the glasses' own capture button.
///
/// The DAT SDK cannot help here: it exposes no gallery, and the hardware button's press event is
/// decoded in its internal transport but never surfaced publicly. A natively-taken photo goes to
/// the Meta AI app instead — and from there into the iOS photo library, which *is* readable.
///
/// So this is a library query, not an SDK call. It never asks for more than read access and never
/// copies anything without the technician choosing it.
enum PhotoLibraryImport {
    /// EXIF `Make` values a Meta device writes. Matched case-insensitively as a prefix, because the
    /// `Model` varies by frame (Ray-Ban Meta, Oakley Meta HSTN, …) while the maker does not.
    private static let metaMakes = ["meta", "facebook", "ray-ban"]

    struct Candidate: Identifiable {
        let asset: PHAsset
        let make: String?
        let model: String?
        var id: String { asset.localIdentifier }
    }

    // MARK: - Diagnosis

    /// One-shot probe: what albums exist, and what the recent photos claim to come from.
    ///
    /// Written because the answer is device-specific — whether the Meta AI app syncs to the
    /// library at all, and whether its photos carry identifying EXIF, is not documented anywhere
    /// and differs by the user's own sync settings.
    static func diagnose() async {
        guard await requestReadAccess() else {
            Diag.log("gallery", "photo library access denied — cannot look for glasses photos")
            return
        }

        // `.limited` makes the library look EMPTY rather than refused: the app sees only the
        // assets the user hand-picked. Without this line an empty result is unreadable — it could
        // equally mean "no photos on the phone" or "access scoped to nothing".
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let statusName: String
        switch status {
        case .authorized: statusName = "authorized (full)"
        case .limited: statusName = "LIMITED — app sees only hand-picked photos"
        case .denied: statusName = "denied"
        case .restricted: statusName = "restricted"
        case .notDetermined: statusName = "notDetermined"
        @unknown default: statusName = "unknown"
        }

        let allImages = PHAsset.fetchAssets(with: .image, options: nil).count
        let allVideos = PHAsset.fetchAssets(with: .video, options: nil).count
        Diag.log("gallery", "access=\(statusName) · visible images=\(allImages) videos=\(allVideos)")

        var albumNames: [String] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle {
                    let count = PHAsset.fetchAssets(in: collection, options: nil).count
                    if count > 0 { albumNames.append("\(title)(\(count))") }
                }
            }
        }
        Diag.log("gallery", "albums: \(albumNames.joined(separator: ", "))")

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 25
        let recent = PHAsset.fetchAssets(with: options)

        var seen: [String: Int] = [:]
        for index in 0..<recent.count {
            let asset = recent.object(at: index)
            let (make, model) = await metadata(of: asset)
            let key = "\(make ?? "—")/\(model ?? "—")"
            seen[key, default: 0] += 1
        }
        Diag.log(
            "gallery",
            "recent \(recent.count) photos by source: "
                + seen.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", ")
        )
    }

    // MARK: - Import

    /// The album the Meta AI app creates for photos it imports off the glasses.
    private static let metaAlbumTitles = ["Meta AI", "Meta View"]

    /// Photos in the library that came from Meta glasses, newest first.
    ///
    /// Prefers the Meta AI album: it is one indexed fetch, where identifying photos by EXIF means
    /// reading the header of every asset in the library — on a phone with 1,300 photos that is
    /// hundreds of file reads for an answer the album already gives.
    static func glassesPhotos(limit: Int = 200) async -> [Candidate] {
        guard await requestReadAccess() else { return [] }

        if let album = metaAlbum() {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit
            let assets = PHAsset.fetchAssets(in: album, options: options)

            var candidates: [Candidate] = []
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image else { return }
                candidates.append(Candidate(asset: asset, make: "Meta AI", model: nil))
            }
            Diag.log("gallery", "found \(candidates.count) photo(s) in the Meta AI album")
            return candidates
        }

        // No album — fall back to an EXIF scan over a bounded recent window, so a library with no
        // Meta album does not turn into an unbounded read of every photo on the phone.
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 300
        let assets = PHAsset.fetchAssets(with: options)

        var candidates: [Candidate] = []
        for index in 0..<assets.count where candidates.count < limit {
            let asset = assets.object(at: index)
            let (make, model) = await metadata(of: asset)
            guard isMeta(make: make, model: model) else { continue }
            candidates.append(Candidate(asset: asset, make: make, model: model))
        }
        Diag.log("gallery", "found \(candidates.count) glasses photo(s) by EXIF scan")
        return candidates
    }

    static func metaAlbum() -> PHAssetCollection? {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        var found: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if let title = collection.localizedTitle, metaAlbumTitles.contains(title) {
                found = collection
                stop.pointee = true
            }
        }
        return found
    }

    /// A thumbnail for the picker grid. Stays local — no iCloud round trip just to browse.
    static func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, info in
                // Opportunistic delivery calls back twice — a degraded image first.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    static func isMeta(make: String?, model: String?) -> Bool {
        let haystack = "\(make ?? "") \(model ?? "")".lowercased()
        return metaMakes.contains { haystack.contains($0) }
    }

    /// Full-size JPEG for upload, with orientation baked in — the same trap the proposal
    /// documents fall into applies to a library photo just as much as a streamed one.
    static func jpeg(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // the original may only exist in iCloud
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return JPEGOrientation.normalized(data)
    }

    // MARK: - Plumbing

    private static func metadata(of asset: PHAsset) async -> (make: String?, model: String?) {
        // Reads only the header, not the pixels: requesting full image data for 25 assets to
        // learn their maker would pull originals down from iCloud.
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto
        }) else { return (nil, nil) }

        var header = Data()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var finished = false
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    guard header.count < 96_000 else { return }
                    header.append(chunk)
                },
                completionHandler: { _ in
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: Self.exifMakeModel(header))
                }
            )
        }
    }

    private static func exifMakeModel(_ data: Data) -> (make: String?, model: String?) {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        else { return (nil, nil) }
        return (tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String)
    }

    private static func requestReadAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        let granted = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        return granted == .authorized || granted == .limited
    }
}
