import Foundation

/// Talks to the login service — the only thing that mints tokens. copilot-server has no login
/// endpoint at all; it shares the signing secret and verifies what this returns.
struct AuthClient {
    private let base: URL
    private let session: URLSession

    init(base: URL = APIConfig.loginBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        var request = URLRequest(url: base.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Registration stores emails lowercase and the service compares case-sensitively, so
        // `ALEX@…` 401s where `alex@…` succeeds. Normalise here, exactly as the web client does.
        request.httpBody = try JSONEncoder().encode([
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ])
        // Login answers in well under a second; on a black-holed field network the default
        // timeout reads as a frozen screen.
        request.timeoutInterval = 15

        Diag.log("auth", "POST \(request.url?.absoluteString ?? "?") as \(Diag.redact(email))")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Diag.log("auth", "login ← HTTP \(status), \(data.count) bytes")
            return try ResponseDecoder.unwrap(LoginResponse.self, data: data, response: response)
        } catch let error as URLError {
            // The transport failed — no HTTP status exists. This is the branch that tells DNS,
            // no-route and TLS apart, and it is invisible without the code.
            Diag.log("auth", "login transport failed: \(error.code.rawValue) \(error.localizedDescription)")
            throw error
        } catch {
            Diag.log("auth", "login failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Exchanges the refresh token for a new access token.
    ///
    /// The response shape is read leniently: this endpoint has shipped the token at several
    /// different keys, and the web client tolerates all of them rather than breaking on a deploy.
    func refresh(refreshToken: String) async throws -> AuthTokens {
        var request = URLRequest(url: base.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status) }

        guard let tokens = Self.extractTokens(from: data, fallbackRefresh: refreshToken) else {
            throw APIError.emptyResponse
        }
        return tokens
    }

    func logout(refreshToken: String) async {
        var request = URLRequest(url: base.appendingPathComponent("auth/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])
        request.timeoutInterval = 10
        // Best effort: local state is cleared either way, same as the web client.
        _ = try? await session.data(for: request)
    }

    /// Pulls the tokens out of whichever shape the refresh endpoint used — wrapped in `data` or
    /// bare, snake_case or camelCase, top-level or nested under `tokens`.
    static func extractTokens(from data: Data, fallbackRefresh: String) -> AuthTokens? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let body = (root["data"] as? [String: Any]) ?? root
        let nested = body["tokens"] as? [String: Any]

        let access = (body["access_token"] as? String)
            ?? (body["accessToken"] as? String)
            ?? (body["token"] as? String)
            ?? (nested?["accessToken"] as? String)
            ?? (nested?["access_token"] as? String)
        guard let access, !access.isEmpty else { return nil }

        let refresh = (body["refresh_token"] as? String)
            ?? (body["refreshToken"] as? String)
            ?? (nested?["refreshToken"] as? String)
            ?? (nested?["refresh_token"] as? String)

        return AuthTokens(accessToken: access, refreshToken: refresh ?? fallbackRefresh)
    }
}
