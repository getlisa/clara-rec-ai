import Foundation

/// Both backends answer with the same envelope: `{ data, error }`. A failure carries a status and
/// message, and sometimes a `code` the UI has to branch on rather than just showing.
struct APIEnvelope<T: Decodable>: Decodable {
    let data: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable, Equatable {
    let status: Int?
    let message: String?
    /// Set on the errors the UI must react to rather than toast — `OPTION_CHOICE_REQUIRED`,
    /// `TAX_RATE_UNAVAILABLE`. Absent on ordinary failures.
    let code: String?
}

enum APIError: LocalizedError, Equatable {
    /// The server answered with an `error` body.
    case server(status: Int, message: String, code: String?)
    /// A non-2xx with nothing decodable in it.
    case http(status: Int)
    /// 2xx, but `data` was null and the caller needed a value.
    case emptyResponse
    case notAuthenticated
    case badURL

    var errorDescription: String? {
        switch self {
        case .server(_, let message, _): return message
        case .http(let status) where status == 401: return "Your session has expired. Sign in again."
        case .http(let status): return "The server returned an error (HTTP \(status))."
        case .emptyResponse: return "The server returned no data."
        case .notAuthenticated: return "You are not signed in."
        case .badURL: return "Could not build the request URL."
        }
    }

    /// The server's `error.code`, when it sent one.
    var code: String? {
        if case .server(_, _, let code) = self { return code }
        return nil
    }

    var status: Int? {
        switch self {
        case .server(let status, _, _): return status
        case .http(let status): return status
        default: return nil
        }
    }

    var isUnauthorized: Bool { status == 401 }
}

enum ResponseDecoder {
    /// Prisma serialises timestamps as ISO-8601 with fractional seconds (`2026-09-22T14:30:00.000Z`),
    /// but not every field goes through it — so both spellings are accepted rather than failing a
    /// whole quote on one timestamp.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date: \(text)")
            )
        }
        return decoder
    }()

    /// Unwraps `{ data, error }`, preferring the server's own message over the status code.
    static func unwrap<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? decoder.decode(APIEnvelope<T>.self, from: data)

        // A 2xx that would not decode is a model/server mismatch, and it otherwise surfaces as the
        // misleading "returned no data". Say what actually broke, while the payload is in hand.
        if envelope?.data == nil, (200..<300).contains(status) {
            do {
                _ = try decoder.decode(APIEnvelope<T>.self, from: data)
            } catch {
                Diag.log("api", "decode failed for \(T.self): \(error)")
                Diag.log("api", "body: \(String(decoding: data.prefix(700), as: UTF8.self))")
            }
        }

        if let error = envelope?.error, let message = error.message {
            throw APIError.server(status: error.status ?? status, message: message, code: error.code)
        }
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status)
        }
        guard let value = envelope?.data else {
            // A 2xx whose body isn't the envelope shape at all — try the bare payload, which some
            // endpoints have shipped.
            if let bare = try? decoder.decode(T.self, from: data) { return bare }
            throw APIError.emptyResponse
        }
        return value
    }

    /// For calls whose body doesn't matter — only that they succeeded.
    static func ensureSuccess(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let envelope = try? decoder.decode(APIEnvelope<AnyNull>.self, from: data),
           let error = envelope.error, let message = error.message {
            throw APIError.server(status: error.status ?? status, message: message, code: error.code)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status: status) }
    }

    /// Placeholder for envelopes whose `data` is irrelevant.
    struct AnyNull: Decodable {}
}
