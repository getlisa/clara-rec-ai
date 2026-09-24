import XCTest

/// Both backends answer `{ data, error }`, and two of copilot-server's error codes drive UI rather
/// than a toast — so the code has to survive decoding, not just the message.
final class APIEnvelopeTests: XCTestCase {
    private struct Quote: Decodable, Equatable {
        let id: String
        let status: String
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example/quotes")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    private func unwrap<T: Decodable>(_ type: T.Type, _ json: String, _ status: Int) throws -> T {
        try ResponseDecoder.unwrap(type, data: Data(json.utf8), response: response(status))
    }

    func testUnwrapsTheDataMember() throws {
        let quote = try unwrap(Quote.self, #"{"data":{"id":"q1","status":"DRAFT"},"error":null}"#, 200)
        XCTAssertEqual(quote, Quote(id: "q1", status: "DRAFT"))
    }

    /// The live login service returns exactly this on an empty body.
    func testSurfacesTheServersOwnMessage() {
        let json = #"{"data":null,"error":{"status":400,"message":"Validation failed"}}"#
        XCTAssertThrowsError(try unwrap(Quote.self, json, 400)) { error in
            XCTAssertEqual(error as? APIError,
                           .server(status: 400, message: "Validation failed", code: nil))
            XCTAssertEqual((error as? APIError)?.errorDescription, "Validation failed")
        }
    }

    /// OPTION_CHOICE_REQUIRED means "show a radio list", not "show a toast" — losing the code
    /// would make completing an either/or quote impossible.
    func testKeepsTheErrorCodeTheUIHasToBranchOn() {
        let json = """
        {"data":null,"error":{"status":409,"message":"Pick the option the customer chose",
        "code":"OPTION_CHOICE_REQUIRED"}}
        """
        XCTAssertThrowsError(try unwrap(Quote.self, json, 409)) { error in
            XCTAssertEqual((error as? APIError)?.code, "OPTION_CHOICE_REQUIRED")
            XCTAssertEqual((error as? APIError)?.status, 409)
        }
    }

    func testUnauthorizedIsRecognisableSoTheClientCanRefreshOnce() {
        let json = #"{"data":null,"error":{"status":401,"message":"Access token expired"}}"#
        XCTAssertThrowsError(try unwrap(Quote.self, json, 401)) { error in
            XCTAssertEqual((error as? APIError)?.isUnauthorized, true)
        }
    }

    /// A gateway failure isn't JSON at all — the staging 504 returns
    /// `{"message": "Network error communicating with endpoint"}` with no envelope.
    func testNonEnvelopeFailuresStillRaiseTheStatus() {
        let json = #"{"message":"Network error communicating with endpoint"}"#
        XCTAssertThrowsError(try unwrap(Quote.self, json, 504)) { error in
            XCTAssertEqual(error as? APIError, .http(status: 504))
        }
    }

    /// Some endpoints have shipped the payload bare rather than wrapped.
    func testFallsBackToABarePayloadOnSuccess() throws {
        let quote = try unwrap(Quote.self, #"{"id":"q1","status":"COMPLETED"}"#, 200)
        XCTAssertEqual(quote.status, "COMPLETED")
    }

    func testEmptyDataOnSuccessIsAnError() {
        XCTAssertThrowsError(try unwrap(Quote.self, #"{"data":null,"error":null}"#, 200)) { error in
            XCTAssertEqual(error as? APIError, .emptyResponse)
        }
    }

    func testEnsureSuccessAcceptsABodyItCannotDecode() throws {
        // The proposal PDF download answers with binary on success.
        try ResponseDecoder.ensureSuccess(data: Data([0x25, 0x50, 0x44, 0x46]), response: response(200))
    }

    func testEnsureSuccessStillReportsAnErrorEnvelope() {
        let json = #"{"data":null,"error":{"status":409,"message":"Quote is Completed and frozen"}}"#
        XCTAssertThrowsError(
            try ResponseDecoder.ensureSuccess(data: Data(json.utf8), response: response(409))
        ) { error in
            XCTAssertEqual((error as? APIError)?.errorDescription, "Quote is Completed and frozen")
        }
    }
}

/// The photo upload must use the field name the server reads with `imageUpload.array("images")`.
final class MultipartBodyTests: XCTestCase {
    func testUsesTheImagesFieldNameAndAJPEGContentType() throws {
        let body = MultipartBody.jpegs([Data([0xFF, 0xD8, 0xFF])])
        let text = String(decoding: body.data, as: UTF8.self)

        XCTAssertTrue(body.contentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(text.contains(#"name="images""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.contains(".jpg"))
    }

    /// multer is configured with `files: 4` and rejects the request past that, so the client
    /// batches rather than letting the whole upload fail.
    func testCapsEachRequestAtTheServersFourFileLimit() {
        let body = MultipartBody.jpegs(Array(repeating: Data([0xFF]), count: 9))
        let parts = String(decoding: body.data, as: UTF8.self)
            .components(separatedBy: #"name="images""#).count - 1
        XCTAssertEqual(parts, MultipartBody.maxFiles)
    }

    func testClosesWithTheTerminatingBoundary() {
        let body = MultipartBody.jpegs([Data([0xFF])])
        let boundary = body.contentType.replacingOccurrences(
            of: "multipart/form-data; boundary=", with: ""
        )
        XCTAssertTrue(String(decoding: body.data, as: UTF8.self).hasSuffix("--\(boundary)--\r\n"))
    }
}
