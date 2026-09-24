import Foundation
import os

/// Uploads a captured photo to S3 with a single signed PUT.
struct S3ImageUploader {
    struct Upload: Equatable {
        let key: String
        let bucket: String
        let sizeBytes: Int

        var uri: String { "s3://\(bucket)/\(key)" }
    }

    enum UploadError: LocalizedError {
        case notConfigured
        case bucketNameHasDot
        case badURL
        case rejected(status: Int, code: String?)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "S3 is not configured"
            case .bucketNameHasDot:
                return "Bucket name contains a dot, which breaks HTTPS for S3 virtual-hosted URLs"
            case .badURL:
                return "Could not build the S3 URL"
            case .rejected(let status, let code):
                if let code, !code.isEmpty { return "S3 \(code) (HTTP \(status))" }
                if status == 403 { return "S3 rejected the credentials (HTTP 403)" }
                return "S3 upload failed (HTTP \(status))"
            }
        }
    }

    private static let logger = Logger(
        subsystem: "ai.justclara.ClaraAssistant", category: "S3Upload"
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `jpeg` is the JPEG the glasses produced — the SDK already returns encoded data, so there
    /// is no decode/re-encode round trip here.
    func upload(
        config: S3Config,
        author: Author,
        jpeg: Data,
        capturedAt: Date = Date()
    ) async throws -> Upload {
        guard config.isConfigured else { throw UploadError.notConfigured }
        guard !config.hasDotInBucketName else { throw UploadError.bucketNameHasDot }

        let payloadSha256 = AwsV4Signer.sha256Hex(jpeg)
        let key = objectKey(
            config: config, author: author, capturedAt: capturedAt, payloadSha256: payloadSha256
        )

        var metadata = [
            "content-type": "image/jpeg",
            "x-amz-meta-author-id": author.id,
            "x-amz-meta-captured-at": Self.iso8601.string(from: capturedAt),
            "x-amz-meta-source": "clara-assistant-ios",
        ]
        if let name = asciiOrNil(author.name) {
            metadata["x-amz-meta-author-name"] = name
        }
        if !config.sessionToken.isEmpty {
            metadata["x-amz-security-token"] = config.sessionToken
        }

        let signedHeaders = AwsV4Signer.sign(
            method: "PUT",
            host: config.host,
            key: key,
            headers: metadata,
            payloadSha256: payloadSha256,
            accessKeyId: config.accessKeyId,
            secretAccessKey: config.secretAccessKey,
            region: config.region,
            timestamp: Date()
        )

        guard let url = URL(string: "https://\(config.host)/\(AwsV4Signer.encodeKey(key))") else {
            throw UploadError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await session.upload(for: request, from: jpeg)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.rejected(status: -1, code: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = Self.s3ErrorCode(in: body)
            Self.logger.error(
                "S3 PUT failed: status=\(http.statusCode, privacy: .public) code=\(code ?? "none", privacy: .public)"
            )
            throw UploadError.rejected(status: http.statusCode, code: code)
        }

        Self.logger.info("S3 PUT ok: \(key, privacy: .public) (\(jpeg.count, privacy: .public) bytes)")
        return Upload(key: key, bucket: config.bucket, sizeBytes: jpeg.count)
    }

    /// `photos/<author>/<yyyy>/<MM>/<dd>/<yyyyMMdd-HHmmss>-<content hash>.jpg`
    ///
    /// The author prefix keeps each person's images separate; the content hash suffix means the
    /// very same photo re-uploaded within a second lands on the same key instead of duplicating.
    private func objectKey(
        config: S3Config,
        author: Author,
        capturedAt: Date,
        payloadSha256: String
    ) -> String {
        let day = Self.dayFormatter.string(from: capturedAt)
        let stamp = Self.stampFormatter.string(from: capturedAt)
        return "\(config.rootPrefix)/\(author.storagePrefix)/\(day)/\(stamp)-\(payloadSha256.prefix(12)).jpg"
    }

    /// S3 user metadata must be US-ASCII, so anything else is dropped rather than failing the
    /// upload.
    private func asciiOrNil(_ raw: String) -> String? {
        let filtered = String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .unicodeScalars
                .filter { $0.value >= 0x20 && $0.value <= 0x7E }
        )
        .trimmingCharacters(in: .whitespaces)
        .prefix(128)
        return filtered.isEmpty ? nil : String(filtered)
    }

    static func s3ErrorCode(in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8),
              let open = text.range(of: "<Code>"),
              let close = text.range(of: "</Code>"),
              open.upperBound <= close.lowerBound
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static let dayFormatter = utcFormatter("yyyy/MM/dd")
    private static let stampFormatter = utcFormatter("yyyyMMdd-HHmmss")
    private static let iso8601 = utcFormatter("yyyy-MM-dd'T'HH:mm:ss'Z'")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
