import Foundation

/// The technician the login service returned. Only the fields the app actually shows are decoded;
/// the payload carries more, and `decodeIfPresent` keeps a shape change from failing the login.
struct AuthUser: Codable, Equatable {
    let id: String?
    let email: String?
    let firstName: String?
    let lastName: String?
    let role: String?
    let companyId: Int?

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return email ?? "Signed in"
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, role
        case firstName = "first_name"
        case lastName = "last_name"
        case companyId = "company_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The service has shipped both `id: "3"` and `id: 3`.
        if let s = try? c.decodeIfPresent(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = nil
        }
        email = try c.decodeIfPresent(String.self, forKey: .email)
        firstName = try? c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try? c.decodeIfPresent(String.self, forKey: .lastName)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        companyId = try? c.decodeIfPresent(Int.self, forKey: .companyId)
    }

    init(id: String?, email: String?, firstName: String? = nil, lastName: String? = nil,
         role: String?, companyId: Int?) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.role = role
        self.companyId = companyId
    }
}

struct AuthTokens: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
}

struct LoginResponse: Decodable {
    let user: AuthUser
    let tokens: AuthTokens
}

/// The access token's payload, as `authMiddleware` reads it.
///
/// Decoded locally only to show who is signed in and to pre-empt an expired token; the server is
/// the only thing that actually verifies the signature.
struct JWTClaims: Equatable {
    let userId: String?
    let email: String?
    let role: String?
    let companyId: Int?
    let type: String?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// True once the token is within `leeway` of expiry — refresh before spending a request on a 401.
    func expires(within leeway: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= leeway
    }

    /// Parses the payload segment of a JWT. Returns nil for anything that isn't three
    /// base64url segments with a JSON middle — never throws, because a malformed token is a
    /// sign-out, not a crash.
    static func decode(_ token: String) -> JWTClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }

        let companyId: Int?
        if let n = json["companyId"] as? Int { companyId = n }
        else if let s = json["companyId"] as? String { companyId = Int(s) }
        else { companyId = nil }

        let expiresAt: Date?
        if let exp = json["exp"] as? Double { expiresAt = Date(timeIntervalSince1970: exp) }
        else if let exp = json["exp"] as? Int { expiresAt = Date(timeIntervalSince1970: Double(exp)) }
        else { expiresAt = nil }

        return JWTClaims(
            userId: json["userId"] as? String ?? (json["userId"] as? Int).map(String.init),
            email: json["email"] as? String,
            role: json["role"] as? String,
            companyId: companyId,
            type: json["type"] as? String,
            expiresAt: expiresAt
        )
    }

    /// JWT uses base64url without padding; Foundation's decoder needs both put back.
    static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
