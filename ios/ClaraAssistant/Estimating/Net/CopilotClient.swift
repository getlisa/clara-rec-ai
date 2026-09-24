import Foundation
import os

/// Authenticated calls to copilot-server.
///
/// Mirrors the web client's `authFetch`: on a 401 for a request that carried a token, refresh once
/// and retry, and sign out only when the refresh itself fails.
struct CopilotClient {
    private let base: URL
    private let session: URLSession

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "Copilot")

    /// Nonisolated so API types can be built anywhere, including in a default argument. The
    /// session is reached on the main actor inside `perform`, where there is already a hop.
    init(base: URL = APIConfig.copilotBase) {
        self.base = base
        let config = URLSessionConfiguration.default
        // Per-request budgets are set on each URLRequest (see Timeout); this is the ceiling.
        config.timeoutIntervalForRequest = Timeout.agentTurn
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Requests

    /// Per-call budgets. A cold catalog search takes 15–30s and an agent turn is an LLM call, so
    /// one blanket timeout either strangles those or lets an ordinary read hang for two minutes.
    enum Timeout {
        static let standard: TimeInterval = 30
        static let agentTurn: TimeInterval = 120
        static let priceSearch: TimeInterval = 60
        static let download: TimeInterval = 120
    }

    func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = Timeout.standard
    ) async throws -> T {
        try await send(path, method: "GET", query: query, body: nil, contentType: nil, timeout: timeout)
    }

    func post<T: Decodable>(
        _ path: String,
        json: Encodable? = nil,
        timeout: TimeInterval = Timeout.standard
    ) async throws -> T {
        let body = try json.map { try JSONEncoder().encode(AnyEncodable($0)) }
        return try await send(path, method: "POST", body: body, contentType: "application/json", timeout: timeout)
    }

    func patch<T: Decodable>(_ path: String, json: Encodable) async throws -> T {
        let body = try JSONEncoder().encode(AnyEncodable(json))
        return try await send(path, method: "PATCH", body: body, contentType: "application/json")
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send(path, method: "DELETE", body: nil, contentType: nil)
    }

    /// Multipart upload — used for quote photos, where the field name must be `images`.
    func upload<T: Decodable>(_ path: String, multipart: MultipartBody) async throws -> T {
        try await send(
            path,
            method: "POST",
            body: multipart.data,
            contentType: multipart.contentType,
            timeout: Timeout.download
        )
    }

    /// Raw bytes, for the proposal PDF and .docx downloads.
    func download(_ path: String) async throws -> Data {
        let (data, response) = try await perform(
            path, method: "GET", query: [], body: nil, contentType: nil, timeout: Timeout.download
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A failure here is still JSON, even though success is binary.
            try ResponseDecoder.ensureSuccess(data: data, response: response)
            throw APIError.http(status: status)
        }
        return data
    }

    // MARK: - Plumbing

    private func send<T: Decodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval = Timeout.standard
    ) async throws -> T {
        let (data, response) = try await perform(
            path, method: method, query: query, body: body, contentType: contentType, timeout: timeout
        )
        return try ResponseDecoder.unwrap(T.self, data: data, response: response)
    }

    private func perform(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        guard var token = await AuthSession.shared.validAccessToken() else {
            throw APIError.notAuthenticated
        }

        var attempt = try makeRequest(path, method, query, body, contentType, token: token, timeout: timeout)
        Diag.log("api", "\(method) \(path) token=\(Diag.token(token))")

        var data: Data
        var response: URLResponse
        do {
            (data, response) = try await session.data(for: attempt)
        } catch let error as URLError {
            Diag.log("api", "\(method) \(path) transport failed: \(error.code.rawValue) \(error.localizedDescription)")
            throw error
        }
        Diag.log("api", "\(method) \(path) ← HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")

        if (response as? HTTPURLResponse)?.statusCode == 401 {
            Self.logger.info("401 on \(path, privacy: .public) — refreshing once")
            guard let refreshed = await AuthSession.shared.refreshAfterUnauthorized() else {
                throw APIError.notAuthenticated
            }
            token = refreshed
            attempt = try makeRequest(path, method, query, body, contentType, token: token, timeout: timeout)
            (data, response) = try await session.data(for: attempt)
        }

        return (data, response)
    }

    private func makeRequest(
        _ path: String,
        _ method: String,
        _ query: [URLQueryItem],
        _ body: Data?,
        _ contentType: String?,
        token: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let url = base.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let final = components.url else { throw APIError.badURL }

        var request = URLRequest(url: final)
        request.timeoutInterval = timeout
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The server stamps quotes with the technician's local time; the web client sends this on
        // every call and so must this one.
        request.setValue(APIConfig.deviceTimeZone, forHTTPHeaderField: "X-Device-Timezone")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

/// Lets a heterogeneous `Encodable` be encoded without making every call site generic.
struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
