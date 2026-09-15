import Photos
import os

/// Saves finished recordings to the photo library, in a dedicated album so the Clips tab
/// can list exactly the app's own recordings. This is the iOS counterpart of the Android
/// build's MediaStore export.
enum PhotoLibrarySaver {

    static let albumName = "Clara-Assistant"

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "PhotoLibrary")

    enum SaveError: LocalizedError {
        case permissionDenied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Photos access denied"
            case .failed(let reason): return reason
            }
        }
    }

    static func save(videoAt url: URL) async throws {
        guard await requestAccess() else { throw SaveError.permissionDenied }

        let album = try await findOrCreateAlbum()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: .video, fileURL: url, options: nil)
                if let album, let placeholder = creation.placeholderForCreatedAsset {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
                }
            }
            // The library holds its own copy now.
            try? FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to save recording: \(error.localizedDescription, privacy: .public)")
            throw SaveError.failed(error.localizedDescription)
        }
    }

    static func requestAccess() async -> Bool {
        // .readWrite rather than .addOnly: the Clips tab has to read the album back.
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        return status == .authorized || status == .limited
    }

    static func existingAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        ).firstObject
    }

    private static func findOrCreateAlbum() async throws -> PHAssetCollection? {
        if let existing = existingAlbum() { return existing }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            }
        } catch {
            // A missing album is not fatal: the recording still lands in the library.
            Self.logger.error("Could not create album: \(error.localizedDescription, privacy: .public)")
        }
        return existingAlbum()
    }
}
