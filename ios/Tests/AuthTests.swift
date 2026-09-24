import XCTest

/// The token is the whole basis of the Estimates tab: copilot-server mints nothing and only
/// verifies what the login service signed, so a misread claim is a silent wrong-tenant bug.
final class JWTClaimsTests: XCTestCase {
    /// Header/payload/signature, base64url, unpadded — built by hand so the test doesn't depend
    /// on a live login. Payload is the shape `authMiddleware` reads.
    private func makeToken(payload: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URL(Data(#"{"alg":"HS256"}"#.utf8))).\(base64URL(json)).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testDecodesTheClaimsAuthMiddlewareReads() throws {
        let expiry = Date().addingTimeInterval(7 * 24 * 3600)
        let token = try makeToken(payload: [
            "userId": "42",
            "email": "tech@meridianfire.com",
            "role": "technician",
            "companyId": 9,
            "type": "access",
            "exp": Int(expiry.timeIntervalSince1970),
        ])

        let claims = try XCTUnwrap(JWTClaims.decode(token))
        XCTAssertEqual(claims.userId, "42")
        XCTAssertEqual(claims.email, "tech@meridianfire.com")
        XCTAssertEqual(claims.role, "technician")
        XCTAssertEqual(claims.companyId, 9)
        XCTAssertEqual(claims.type, "access")
        XCTAssertFalse(claims.isExpired)
    }

    func testCompanyIdSurvivesBeingSentAsAString() throws {
        let token = try makeToken(payload: ["companyId": "9", "role": "admin"])
        XCTAssertEqual(JWTClaims.decode(token)?.companyId, 9)
    }

    func testExpiryDrivesIsExpiredAndTheRefreshWindow() throws {
        let past = try makeToken(payload: ["exp": Int(Date().addingTimeInterval(-60).timeIntervalSince1970)])
        XCTAssertTrue(try XCTUnwrap(JWTClaims.decode(past)).isExpired)

        // 30s of life left: still valid, but inside the 60s window that triggers a pre-emptive
        // refresh rather than spending a long request on a token about to die.
        let soon = try makeToken(payload: ["exp": Int(Date().addingTimeInterval(30).timeIntervalSince1970)])
        let claims = try XCTUnwrap(JWTClaims.decode(soon))
        XCTAssertFalse(claims.isExpired)
        XCTAssertTrue(claims.expires(within: 60))
        XCTAssertFalse(claims.expires(within: 10))
    }

    /// A malformed token is a sign-out, never a crash.
    func testMalformedTokensDecodeToNilRatherThanThrowing() {
        XCTAssertNil(JWTClaims.decode(""))
        XCTAssertNil(JWTClaims.decode("not-a-jwt"))
        XCTAssertNil(JWTClaims.decode("a.b"))
        XCTAssertNil(JWTClaims.decode("a.!!!not-base64!!!.c"))
    }

    /// base64url payloads arrive unpadded; Foundation's decoder needs the padding back.
    func testBase64URLPaddingIsRestored() throws {
        for length in 1...8 {
            let original = Data(repeating: 0xAB, count: length)
            let encoded = base64URL(original)
            XCTAssertEqual(JWTClaims.base64URLDecode(encoded), original, "length \(length)")
        }
    }
}

final class LoginResponseTests: XCTestCase {
    /// Exactly what `auth.service.ts` returns, inside the `{ data, error }` envelope.
    func testDecodesTheLoginServicePayload() throws {
        let json = """
        {"data":{"user":{"id":"7","email":"tech@meridianfire.com","first_name":"Alex",
        "last_name":"Iyer","job_title":"Sprinkler Tech","role":"technician","company_id":9},
        "tokens":{"accessToken":"aaa","refreshToken":"rrr","expiresIn":"7d"}},"error":null}
        """
        let response = try ResponseDecoder.unwrap(
            LoginResponse.self,
            data: Data(json.utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        )

        XCTAssertEqual(response.user.email, "tech@meridianfire.com")
        XCTAssertEqual(response.user.displayName, "Alex Iyer")
        XCTAssertEqual(response.user.companyId, 9)
        XCTAssertEqual(response.tokens.accessToken, "aaa")
        XCTAssertEqual(response.tokens.refreshToken, "rrr")
    }

    func testDisplayNameFallsBackToEmailWhenNoNameIsStored() throws {
        let json = """
        {"data":{"user":{"id":"7","email":"tech@meridianfire.com","role":"technician","company_id":9},
        "tokens":{"accessToken":"aaa","refreshToken":"rrr"}},"error":null}
        """
        let response = try ResponseDecoder.unwrap(
            LoginResponse.self,
            data: Data(json.utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        )
        XCTAssertEqual(response.user.displayName, "tech@meridianfire.com")
    }
}

/// The refresh endpoint has shipped the token under several different keys; the web client
/// tolerates all of them rather than breaking on a deploy, and so does this.
final class RefreshTokenShapeTests: XCTestCase {
    private func extract(_ json: String) -> AuthTokens? {
        AuthClient.extractTokens(from: Data(json.utf8), fallbackRefresh: "old-refresh")
    }

    func testReadsEveryShapeTheEndpointHasUsed() {
        XCTAssertEqual(extract(#"{"data":{"accessToken":"a","refreshToken":"r"}}"#)?.accessToken, "a")
        XCTAssertEqual(extract(#"{"access_token":"a","refresh_token":"r"}"#)?.accessToken, "a")
        XCTAssertEqual(extract(#"{"token":"a"}"#)?.accessToken, "a")
        XCTAssertEqual(extract(#"{"data":{"tokens":{"accessToken":"a","refreshToken":"r"}}}"#)?.accessToken, "a")
    }

    /// A rotated refresh token replaces the stored one; an absent one means it didn't rotate.
    func testKeepsTheOldRefreshTokenWhenTheServerDoesNotRotateIt() {
        XCTAssertEqual(extract(#"{"access_token":"a"}"#)?.refreshToken, "old-refresh")
        XCTAssertEqual(extract(#"{"access_token":"a","refresh_token":"new"}"#)?.refreshToken, "new")
    }

    func testRejectsBodiesWithNoAccessToken() {
        XCTAssertNil(extract(#"{"data":null,"error":{"status":401,"message":"nope"}}"#))
        XCTAssertNil(extract(#"{"access_token":""}"#))
        XCTAssertNil(extract("not json"))
    }
}
