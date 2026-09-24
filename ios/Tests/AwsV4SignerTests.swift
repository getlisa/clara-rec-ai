import XCTest

/// A wrong signature shows up only as an opaque S3 403, so the signer is pinned to known-good
/// vectors: the first is AWS's own published "PUT Object" example, the rest were produced with
/// botocore (the implementation behind the AWS CLI). These are the same vectors the Android
/// build asserts, so the two platforms cannot drift apart.
final class AwsV4SignerTests: XCTestCase {
    private let accessKeyId = "AKIAIOSFODNN7EXAMPLE"
    private let secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    private func at(_ amzDate: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try XCTUnwrap(formatter.date(from: amzDate))
    }

    private func signature(_ headers: [String: String]) throws -> String {
        let authorization = try XCTUnwrap(headers["Authorization"])
        let parts = authorization.components(separatedBy: "Signature=")
        return try XCTUnwrap(parts.last)
    }

    /// AWS docs, "Signature Calculation: Transfer Payload in a Single Chunk" — PUT Object.
    func testMatchesAWSPublishedPutObjectExample() throws {
        let signed = AwsV4Signer.sign(
            method: "PUT",
            host: "examplebucket.s3.amazonaws.com",
            key: "test$file.text",
            headers: [
                "date": "Fri, 24 May 2013 00:00:00 GMT",
                "x-amz-storage-class": "REDUCED_REDUNDANCY",
            ],
            payloadSha256: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: "us-east-1",
            timestamp: try at("20130524T000000Z")
        )

        XCTAssertEqual(
            try signature(signed),
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        )
        XCTAssertEqual(
            signed["Authorization"],
            "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, "
                + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        )
    }

    /// The shape this app actually sends: JPEG body plus author metadata.
    func testMatchesBotocoreForAuthorScopedImageUpload() throws {
        let signed = AwsV4Signer.sign(
            method: "PUT",
            host: "examplebucket.s3.us-east-1.amazonaws.com",
            key: "photos/alice-a1b2c3d4/2026/09/22/1758499200000-abcd1234.jpg",
            headers: [
                "Content-Type": "image/jpeg",
                "x-amz-meta-author-id": "a1b2c3d4",
                "x-amz-meta-author-name": "alice",
            ],
            // sha256("hello clara")
            payloadSha256: "c0e9785f45dc3c96075fd042a3aa164e9304860357166055de3567906bd4a59e",
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: "us-east-1",
            timestamp: try at("20260922T000000Z")
        )

        XCTAssertEqual(
            try signature(signed),
            "2aa3664d708e72ffa4eb6a3a36319d960e6445e34251ca08cc6713276828dc73"
        )
    }

    /// Temporary STS credentials, and a key that forces percent-encoding.
    func testMatchesBotocoreWithSessionTokenAndEscapedKey() throws {
        let signed = AwsV4Signer.sign(
            method: "PUT",
            host: "examplebucket.s3.eu-west-1.amazonaws.com",
            key: "photos/bob smith-ff00/2026/09/22/pic (1).jpg",
            headers: [
                "Content-Type": "image/jpeg",
                "x-amz-security-token": "FQoGZXIvYXdzEXAMPLETOKEN",
                "x-amz-meta-author-id": "ff00",
            ],
            // sha256("x")
            payloadSha256: "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881",
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: "eu-west-1",
            timestamp: try at("20260922T000000Z")
        )

        XCTAssertEqual(
            try signature(signed),
            "8b33847dd71f3e48310f04e85babab4d53af22388b58fec3519c22b0a514d496"
        )
    }

    func testHostIsSignedButLeftForURLSessionToSet() throws {
        let signed = AwsV4Signer.sign(
            method: "PUT",
            host: "examplebucket.s3.us-east-1.amazonaws.com",
            key: "photos/a/b.jpg",
            headers: ["Content-Type": "image/jpeg"],
            payloadSha256: "c0e9785f45dc3c96075fd042a3aa164e9304860357166055de3567906bd4a59e",
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: "us-east-1",
            timestamp: try at("20260922T000000Z")
        )

        XCTAssertFalse(signed.keys.contains { $0.lowercased() == "host" })
        XCTAssertEqual(signed["x-amz-date"], "20260922T000000Z")
        XCTAssertEqual(
            signed["x-amz-content-sha256"],
            "c0e9785f45dc3c96075fd042a3aa164e9304860357166055de3567906bd4a59e"
        )
        let authorization = try XCTUnwrap(signed["Authorization"])
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host;"))
    }

    func testKeysArePercentEncodedOnceKeepingSlashes() {
        XCTAssertEqual(AwsV4Signer.encodeKey("photos/a-b/c.jpg"), "photos/a-b/c.jpg")
        XCTAssertEqual(AwsV4Signer.encodeKey("test$file.text"), "test%24file.text")
        XCTAssertEqual(AwsV4Signer.encodeKey("a b/c (1).jpg"), "a%20b/c%20%281%29.jpg")
        // Already-encoded input must not be double-encoded into %2520.
        XCTAssertEqual(AwsV4Signer.encodeKey("a+b"), "a%2Bb")
        // Multi-byte UTF-8.
        XCTAssertEqual(AwsV4Signer.encodeKey("café.jpg"), "caf%C3%A9.jpg")
    }
}
