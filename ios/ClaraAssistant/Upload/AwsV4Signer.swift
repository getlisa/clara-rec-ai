import CryptoKit
import Foundation

/// Minimal AWS Signature Version 4 signer, scoped to exactly what the S3 uploader needs:
/// one request, a fully buffered payload, and no query string.
///
/// Hand-rolled rather than pulled from the AWS SDK for Swift, which would add a large package
/// graph (smithy-swift, aws-crt-swift) for a single PUT. Mirrors the Android implementation in
/// `com.metalens.app.upload.AwsV4Signer`; see AwsV4SignerTests for the AWS-published vector.
enum AwsV4Signer {
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let terminator = "aws4_request"

    /// RFC 3986 unreserved characters — everything else in a path segment is percent-encoded.
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )

    /// Signs the request and returns the headers to add to it.
    ///
    /// `headers` are the extra headers to sign (content-type, x-amz-meta-*, x-amz-security-token).
    /// The returned dictionary also carries `x-amz-date`, `x-amz-content-sha256` and
    /// `Authorization`. `Host` is signed but not returned, because URLSession derives it from
    /// the URL itself.
    static func sign(
        method: String,
        host: String,
        /// Raw, *unencoded* object key with no leading slash.
        key: String,
        headers: [String: String],
        payloadSha256: String,
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        service: String = "s3",
        timestamp: Date
    ) -> [String: String] {
        let amzDate = amzDateFormatter.string(from: timestamp)
        let dateStamp = dateStampFormatter.string(from: timestamp)

        var signed = headers
        signed["host"] = host
        signed["x-amz-content-sha256"] = payloadSha256
        signed["x-amz-date"] = amzDate

        let canonical = canonicalRequest(
            method: method,
            key: key,
            headers: signed,
            payloadSha256: payloadSha256
        )
        let scope = "\(dateStamp)/\(region)/\(service)/\(terminator)"
        let toSign = stringToSign(amzDate: amzDate, scope: scope, canonicalRequest: canonical)

        let derivedKey = signingKey(
            secretAccessKey: secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hex(hmacSha256(key: derivedKey, data: Data(toSign.utf8)))

        let authorization = "\(algorithm) Credential=\(accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaderNames(signed)), "
            + "Signature=\(signature)"

        // Host is excluded: URLSession sets it from the URL, and setting it twice would break
        // the match.
        var result = signed.filter { $0.key.lowercased() != "host" }
        result["Authorization"] = authorization
        return result
    }

    static func canonicalRequest(
        method: String,
        key: String,
        headers: [String: String],
        payloadSha256: String
    ) -> String {
        let canonicalHeaders = headers
            .map { ($0.key.lowercased(), normalizeHeaderValue($0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()

        return [
            method,
            "/" + encodeKey(key),
            // No query string on a plain PUT Object.
            "",
            canonicalHeaders,
            signedHeaderNames(headers),
            payloadSha256,
        ].joined(separator: "\n")
    }

    static func stringToSign(amzDate: String, scope: String, canonicalRequest: String) -> String {
        [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
    }

    private static func signedHeaderNames(_ headers: [String: String]) -> String {
        headers.keys
            .map { $0.lowercased() }
            .sorted()
            .joined(separator: ";")
    }

    /// S3 percent-encodes the object key once (unlike most services, which encode twice),
    /// keeping `/` as the path separator.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                var out = ""
                for byte in Array(segment.utf8) {
                    if unreserved.contains(byte) {
                        out.append(Character(UnicodeScalar(byte)))
                    } else {
                        out += String(format: "%%%02X", byte)
                    }
                }
                return out
            }
            .joined(separator: "/")
    }

    /// SigV4 trims the value and collapses runs of internal whitespace.
    private static func normalizeHeaderValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func signingKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> Data {
        let date = hmacSha256(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let regional = hmacSha256(key: date, data: Data(region.utf8))
        let serviceKey = hmacSha256(key: regional, data: Data(service.utf8))
        return hmacSha256(key: serviceKey, data: Data(terminator.utf8))
    }

    private static func hmacSha256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let amzDateFormatter: DateFormatter = utcFormatter("yyyyMMdd'T'HHmmss'Z'")
    private static let dateStampFormatter: DateFormatter = utcFormatter("yyyyMMdd")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        // Fixed locale: a user on a non-Gregorian calendar would otherwise produce dates AWS
        // cannot parse.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
