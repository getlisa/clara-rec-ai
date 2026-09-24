import Photos

/// Watches the Meta AI album and reports photos that appear *after* watching starts.
///
/// This is how a press of the glasses' own capture button reaches the estimate. The DAT SDK never
/// publishes that button, but the photo itself travels: glasses → Meta AI app → the "Meta AI"
/// album in the iOS photo library. `PHPhotoLibraryChangeObserver` tells us the moment it lands.
///
/// Two rules it holds to, because this runs unattended:
///
/// **Only photos newer than the watch.** Everything already in the album when watching begins is
/// recorded as seen, so switching this on never back-fills someone's existing photos into a quote.
///
/// **Only the Meta AI album.** Never the camera roll. A technician's personal photos are not
/// candidates for a customer's proposal.
@MainActor
final class GlassesPhotoWatcher: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var isWatching = false

    private var fetchResult: PHFetchResult<PHAsset>?
    /// Assets present when watching began, plus everything already handed to the callback.
    private var seen: Set<String> = []
    private var onNewPhotos: (([PHAsset]) -> Void)?

    /// What was already in the album the first time this watch started.
    ///
    /// Membership, not timestamps, is what separates old from new. A photo taken at 14:00 and
    /// synced by the Meta AI app at 14:25 still carries a creation date of 14:00 — so comparing
    /// creation dates against the watch start throws away exactly the photos this feature exists
    /// to catch. Anything not in this set arrived after we started looking, whenever it was taken.
    private var initial: Set<String>?

    /// Starts watching. Returns false when there is no Meta AI album to watch — which means the
    /// Meta AI app has never imported a photo on this phone.
    @discardableResult
    func start(onNewPhotos: @escaping ([PHAsset]) -> Void) -> Bool {
        let resuming = initial != nil
        stop(keepingHistory: true)

        guard let album = PhotoLibraryImport.metaAlbum() else {
            Diag.log("watch", "no Meta AI album — nothing to watch")
            return false
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album, options: options)

        if initial == nil {
            // First start: everything already in the album is the baseline.
            var baseline: Set<String> = []
            result.enumerateObjects { asset, _, _ in baseline.insert(asset.localIdentifier) }
            initial = baseline
        }
        let baseline = initial ?? []

        fetchResult = result
        self.onNewPhotos = onNewPhotos
        isWatching = true
        PHPhotoLibrary.shared().register(self)

        // Anything the album gained while the screen was away still counts, whenever it was taken.
        var missed: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image,
                  !baseline.contains(asset.localIdentifier),
                  !self.seen.contains(asset.localIdentifier)
            else { return }
            missed.append(asset)
        }

        if resuming, !missed.isEmpty {
            missed.forEach { seen.insert($0.localIdentifier) }
            Diag.log("watch", "resumed; catching up \(missed.count) photo(s) taken while away")
            onNewPhotos(missed)
        } else {
            Diag.log(
                "watch",
                resuming
                    ? "resumed watching, nothing missed"
                    : "watching Meta AI album (\(baseline.count) existing) — new arrivals are imported"
            )
        }
        return true
    }

    /// `keepingHistory` preserves the start time and the imported set across a restart. Only a
    /// deliberate stop — leaving the quote, or switching hands-free off — forgets them.
    func stop(keepingHistory: Bool = false) {
        if isWatching {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            isWatching = false
            fetchResult = nil
            onNewPhotos = nil
            if !keepingHistory { Diag.log("watch", "stopped watching") }
        }
        guard !keepingHistory else { return }
        seen = []
        initial = nil
    }

    /// Called by Photos on an arbitrary queue.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.handle(changeInstance) }
    }

    private func handle(_ change: PHChange) {
        guard isWatching, let current = fetchResult else { return }
        guard let details = change.changeDetails(for: current) else { return }

        fetchResult = details.fetchResultAfterChanges

        // `insertedObjects` is what the album gained, which is exactly the question — no diffing
        // of the whole album against a remembered list.
        let fresh = details.insertedObjects.filter {
            $0.mediaType == .image && !seen.contains($0.localIdentifier)
        }
        guard !fresh.isEmpty else { return }

        fresh.forEach { seen.insert($0.localIdentifier) }
        Diag.log("watch", "\(fresh.count) new photo(s) landed in the Meta AI album")
        onNewPhotos?(fresh)
    }
}
