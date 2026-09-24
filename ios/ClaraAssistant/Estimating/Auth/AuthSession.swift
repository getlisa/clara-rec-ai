import Foundation
import Observation
import os

/// Who is signed in, and the only place the Estimates tab gets a token from.
///
/// Scoped deliberately: signing out here does not touch recording, Clips or the glasses — those
/// have never needed an account and must keep working for testers who have none.
@MainActor
@Observable
final class AuthSession {
    static let shared = AuthSession()

    private(set) var user: AuthUser?
    private(set) var claims: JWTClaims?
    /// True until the Keychain has been read at launch, so the tab doesn't flash the login form
    /// at someone who is already signed in.
    private(set) var isRestoring = true
    private(set) var isWorking = false

    var isAuthenticated: Bool { user != nil }

    private let client: AuthClient
    private var refreshTask: Task<AuthTokens?, Never>?

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "Auth")

    init(client: AuthClient = AuthClient()) {
        self.client = client
    }

    /// Reads the stored token and rebuilds the signed-in user from its claims. Nothing but the
    /// tokens is persisted — the claims already carry email, role and companyId.
    func restore() {
        defer { isRestoring = false }
        guard let access = TokenStore.read(.accessToken),
              let claims = JWTClaims.decode(access)
        else {
            TokenStore.clear()
            return
        }

        // An access token past its expiry is still usable as identity: the refresh token outlives
        // it, and the first request will refresh. Only a token we cannot read at all is a sign-out.
        self.claims = claims
        user = AuthUser(
            id: claims.userId,
            email: claims.email,
            role: claims.role,
            companyId: claims.companyId
        )
        Self.logger.info("Restored session for role=\(claims.role ?? "unknown", privacy: .public)")
    }

    func signIn(email: String, password: String) async throws {
        isWorking = true
        defer { isWorking = false }

        let response = try await client.login(email: email, password: password)
        TokenStore.write(response.tokens.accessToken, for: .accessToken)
        TokenStore.write(response.tokens.refreshToken, for: .refreshToken)
        claims = JWTClaims.decode(response.tokens.accessToken)
        user = response.user
        Self.logger.info("Signed in, role=\(self.claims?.role ?? "unknown", privacy: .public)")
        Diag.log(
            "auth",
            "signed in role=\(claims?.role ?? "?") company=\(claims?.companyId.map(String.init) ?? "?") "
                + "access=\(Diag.token(response.tokens.accessToken))"
        )
        // A token the server minted but we cannot read is a decoding bug, not a login failure —
        // and it would otherwise look like a successful sign-in with an empty account screen.
        if claims == nil {
            Diag.log("auth", "WARNING token did not decode — claims unavailable")
        }
    }

    func signOut() async {
        isWorking = true
        defer { isWorking = false }

        if let refresh = TokenStore.read(.refreshToken) {
            await client.logout(refreshToken: refresh)
        }
        refreshTask?.cancel()
        refreshTask = nil
        TokenStore.clear()
        user = nil
        claims = nil
    }

    /// A token good enough to send, refreshing first when the current one is at or near expiry.
    ///
    /// Refreshing pre-emptively costs one request and saves a guaranteed 401 on a long-running
    /// call — a 15–30s catalog search is a bad place to discover the token died.
    func validAccessToken() async -> String? {
        guard let access = TokenStore.read(.accessToken) else { return nil }
        if let claims, claims.expires(within: 60) {
            return await refreshTokens()?.accessToken
        }
        return access
    }

    /// Called after a 401 on a request that did carry a token.
    func refreshAfterUnauthorized() async -> String? {
        await refreshTokens()?.accessToken
    }

    /// Single-flight: a burst of concurrent 401s triggers one refresh, not one each.
    private func refreshTokens() async -> AuthTokens? {
        if let existing = refreshTask { return await existing.value }

        let task = Task { [client] () -> AuthTokens? in
            guard let refresh = TokenStore.read(.refreshToken) else { return nil }
            do {
                return try await client.refresh(refreshToken: refresh)
            } catch {
                Self.logger.warning("Refresh failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        refreshTask = task

        let tokens = await task.value
        refreshTask = nil

        guard let tokens else {
            // The refresh itself failed — the session is genuinely over, same as the web client.
            TokenStore.clear()
            user = nil
            claims = nil
            return nil
        }

        TokenStore.write(tokens.accessToken, for: .accessToken)
        TokenStore.write(tokens.refreshToken, for: .refreshToken)
        claims = JWTClaims.decode(tokens.accessToken)
        return tokens
    }
}
