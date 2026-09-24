import Foundation

/// A `multipart/form-data` body, built for the quote photo upload.
///
/// The server reads the files with `imageUpload.array("images")`, so every part must use the field
/// name `images`, and it accepts at most 4 files of 8 MB each per request.
struct MultipartBody {
    static let maxFiles = 4
    static let maxBytesPerFile = 8 * 1024 * 1024

    let data: Data
    let contentType: String

    struct Part {
        let filename: String
        let mimeType: String
        let content: Data
    }

    init(fieldName: String = "images", parts: [Part]) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        for part in parts {
            body.append("--\(boundary)\r\n")
            body.append(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(part.filename)\"\r\n"
            )
            body.append("Content-Type: \(part.mimeType)\r\n\r\n")
            body.append(part.content)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")

        self.data = body
        self.contentType = "multipart/form-data; boundary=\(boundary)"
    }

    /// Convenience for the common case: JPEGs straight off the glasses.
    static func jpegs(_ images: [Data], namePrefix: String = "glasses") -> MultipartBody {
        let parts = images.prefix(maxFiles).enumerated().map { index, content in
            Part(
                filename: "\(namePrefix)-\(Int(Date().timeIntervalSince1970))-\(index).jpg",
                mimeType: "image/jpeg",
                content: content
            )
        }
        return MultipartBody(parts: Array(parts))
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
