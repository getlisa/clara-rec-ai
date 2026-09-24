import Foundation

/// Speech → text, for the estimate chat's mic.
///
/// The one endpoint that does **not** use the `{ data, error }` envelope — it answers
/// `{ success, text }` at the top level, so it gets its own decode rather than going through
/// `ResponseDecoder`.
struct VoiceAPI {
    private let base: URL
    private let session: URLSession

    init(base: URL = APIConfig.copilotBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    private struct Response: Decodable {
        let success: Bool?
        let text: String?
        let error: APIErrorBody?
    }

    /// Returns the transcript. `mimeType` should be whatever the recorder actually produced.
    func transcribe(audio: Data, mimeType: String, language: String = "en") async throws -> String {
        struct Body: Encodable {
            let audioBase64: String
            let mimeType: String
            let language: String
        }

        var request = URLRequest(url: base.appendingPathComponent("api/v1/voice/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(APIConfig.deviceTimeZone, forHTTPHeaderField: "X-Device-Timezone")
        if let token = await AuthSession.shared.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            Body(
                audioBase64: audio.base64EncodedString(),
                mimeType: Self.normalise(mimeType),
                language: language
            )
        )

        Diag.log("voice", "transcribing \(audio.count) bytes as \(Self.normalise(mimeType))")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(Response.self, from: data)

        if let message = decoded?.error?.message {
            throw APIError.server(status: decoded?.error?.status ?? status, message: message, code: decoded?.error?.code)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status: status) }

        guard let text = decoded?.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            Diag.log("voice", "transcription came back empty")
            throw APIError.emptyResponse
        }
        Diag.log("voice", "transcript: \(text.count) chars")
        return text
    }

    /// The server wants a bare type — a recorder's `audio/webm;codecs=opus` has to lose its suffix.
    static func normalise(_ mimeType: String) -> String {
        mimeType.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? mimeType
    }
}
