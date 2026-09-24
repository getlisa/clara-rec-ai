import Foundation

/// Where uploaded images go, and the credentials used to put them there.
///
/// Values come from `ClaraAssistant/Secrets.plist`, which is gitignored — copy
/// `Secrets.example.plist` and fill it in. A plist rather than an `.xcconfig` because xcconfig
/// treats `//` as a comment, and AWS secret keys can legitimately contain it.
///
/// NOTE: anything in the app bundle is readable by anyone who unzips the IPA. The IAM user
/// behind these keys should be able to do nothing except `s3:PutObject` into this one bucket —
/// see the "Image upload to S3" section of the README.
struct S3Config: Equatable {
    let bucket: String
    let region: String
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    /// Key prefix all uploads live under.
    let rootPrefix: String

    var isConfigured: Bool {
        !bucket.isEmpty && !region.isEmpty && !accessKeyId.isEmpty && !secretAccessKey.isEmpty
    }

    /// Virtual-hosted-style endpoint host.
    var host: String { "\(bucket).s3.\(region).amazonaws.com" }

    /// Buckets whose name contains a dot break TLS certificate matching on this style, so those
    /// are rejected up front rather than failing later with an opaque handshake error.
    var hasDotInBucketName: Bool { bucket.contains(".") }

    static let empty = S3Config(
        bucket: "",
        region: "",
        accessKeyId: "",
        secretAccessKey: "",
        sessionToken: "",
        rootPrefix: "photos"
    )

    static func fromBundle(_ bundle: Bundle = .main) -> S3Config {
        guard
            let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
        else {
            return .empty
        }

        func string(_ key: String) -> String {
            (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let region = string("AWS_REGION")
        return S3Config(
            bucket: string("S3_BUCKET"),
            region: region.isEmpty ? "us-east-1" : region,
            accessKeyId: string("AWS_ACCESS_KEY_ID"),
            secretAccessKey: string("AWS_SECRET_ACCESS_KEY"),
            sessionToken: string("AWS_SESSION_TOKEN"),
            rootPrefix: "photos"
        )
    }
}
