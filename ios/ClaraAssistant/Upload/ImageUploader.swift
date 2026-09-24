import Observation
import UIKit

/// Drives image uploads to S3 and exposes just enough state for the live view to report on them.
@MainActor
@Observable
final class ImageUploader {
    enum Status: Equatable {
        case idle
        /// No bucket/credentials configured — uploading is simply off.
        case notConfigured
        case uploading
        case uploaded(uri: String)
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    private(set) var authorPrefix = ""
    /// Shown briefly in the live view so the user sees what was actually captured.
    private(set) var lastCapture: UIImage?

    var isUploading: Bool { status == .uploading }
    var canRetry: Bool { if case .failed = status { return true }; return false }

    private let uploader = S3ImageUploader()
    private var task: Task<Void, Never>?
    private var lastJPEG: Data?
    /// Content hash of the capture already uploaded or in flight, so a repeat delivery from the
    /// SDK doesn't send the same photo twice.
    private var inFlightDigest: String?

    func reset() {
        task?.cancel()
        task = nil
        lastJPEG = nil
        inFlightDigest = nil
        lastCapture = nil
        status = .idle
    }

    /// Uploads `jpeg` unless that exact capture is already uploaded or in flight.
    func uploadIfNeeded(jpeg: Data) {
        let digest = AwsV4Signer.sha256Hex(jpeg)
        if digest == inFlightDigest, !canRetry { return }
        start(jpeg: jpeg, digest: digest)
    }

    /// Re-sends the last capture — used by the retry action.
    func retry() {
        guard let jpeg = lastJPEG else { return }
        start(jpeg: jpeg, digest: AwsV4Signer.sha256Hex(jpeg))
    }

    private func start(jpeg: Data, digest: String) {
        let config = S3Config.fromBundle()
        let author = AuthorIdentity.current

        lastJPEG = jpeg
        lastCapture = UIImage(data: jpeg)
        authorPrefix = author.storagePrefix

        guard config.isConfigured else {
            inFlightDigest = nil
            status = .notConfigured
            return
        }

        inFlightDigest = digest
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            self.status = .uploading
            do {
                let upload = try await uploader.upload(
                    config: config,
                    author: author,
                    jpeg: jpeg,
                    capturedAt: Date()
                )
                guard !Task.isCancelled else { return }
                self.status = .uploaded(uri: upload.uri)
            } catch {
                guard !Task.isCancelled else { return }
                self.inFlightDigest = nil
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.status = .failed(message: message)
            }
        }
    }
}
