import Foundation

/// The two backends the Estimates tab talks to.
///
/// They are separate services that share a JWT signing secret: the login service mints the access
/// token, copilot-server only verifies it. One token authenticates against both.
///
/// NOTE: Release currently points at staging too, because no production copilot-server exists yet.
/// That is deliberate and temporary — repoint `release` the moment one is stood up, or a TestFlight
/// build will be writing real estimates into a dev environment.
enum APIConfig {
    /// Signs the tokens. `POST /auth/login`, `/auth/refresh`, `/auth/logout`.
    static let loginBase = environment.loginBase

    /// Verifies them. `/api/v1/quotes/*`, `/api/v1/companies/*`, `/api/v1/conversations/*`.
    static let copilotBase = environment.copilotBase

    struct Environment {
        let name: String
        let loginBase: URL
        let copilotBase: URL
    }

    static let staging = Environment(
        name: "staging",
        // Mints the tokens. The only host serving /auth/* — copilot-server has no login route.
        loginBase: URL(string: "https://techcopilot-core.justclara.ai/api")!,
        // Host root, without /api: request paths are built as "api/v1/…", matching the web
        // client's `${VITE_COPILOT_BASE_URL}/api/v1`.
        //
        // Replaces the kzrvokx9if API Gateway, which returns 504 — its Lambda integration is
        // unreachable. This host answers /health and returns a proper 401 from authMiddleware.
        copilotBase: URL(string: "https://techcopilot-assistant.justclara.ai")!
    )

    static var environment: Environment {
        #if DEBUG
        return staging
        #else
        // TODO: point at production once copilot-server has a production deployment.
        return staging
        #endif
    }

    /// The server stamps quotes with the technician's local time, so this rides on every request —
    /// the web client sends it too.
    static var deviceTimeZone: String { TimeZone.current.identifier }
}
