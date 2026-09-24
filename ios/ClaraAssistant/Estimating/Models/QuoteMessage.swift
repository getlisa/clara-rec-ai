import Foundation

/// One clarifying question, rendered as tappable options plus an "Other" box.
///
/// The agent is instructed to put questions **only** in this array and never in the reply text,
/// because the UI is expected to render them as buttons. Rendering only the bubble leaves a reply
/// that appears to ask nothing, and the conversation dead-ends.
struct FollowUpQuestion: Decodable, Identifiable, Hashable {
    struct Option: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        /// Sent back as `content` when picked.
        let value: String
    }

    let id: String
    let question: String
    let options: [Option]
    /// Always true — the agent's prompt assumes the UI adds a free-text entry.
    let allowOther: Bool?

    var showsOther: Bool { allowOther ?? true }
}

/// An answer already given, persisted with the answering turn so the card that asked can show
/// its own selection rather than echoing question and answer back as a second bubble.
struct QuestionAnswer: Codable, Hashable {
    let questionId: String
    let question: String
    let value: String
    var fromOther: Bool?
}

struct QuoteMessageAttachment: Decodable, Identifiable, Hashable {
    let id: String
    let url: String?
    let type: String?
    let filename: String?
}

struct QuoteMessage: Decodable, Identifiable, Hashable {
    enum Sender: String, Decodable { case user = "USER", ai = "AI", system = "SYSTEM" }

    let id: String
    let senderType: Sender
    let content: String
    let attachments: [QuoteMessageAttachment]?
    let createdAt: Date

    /// Clarifying questions this turn asked, read out of `metadata.blocks[kind == "questions"]`.
    let questions: [FollowUpQuestion]
    /// Answers this turn submitted, and which AI turn they answer.
    let questionAnswers: [QuestionAnswer]
    let answeredMessageId: String?
    /// Seconds the agent spent thinking, when the server reports it.
    let thinkingDuration: Double?

    var isUser: Bool { senderType == .user }

    /// A turn that only submits answers to a question card. The card shows them, so rendering it
    /// as its own bubble would repeat every question and answer back at the technician.
    var isAnswerEcho: Bool {
        isUser && !questionAnswers.isEmpty && answeredMessageId != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, senderType, content, attachments, createdAt, metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderType = (try? c.decode(Sender.self, forKey: .senderType)) ?? .system
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        attachments = try? c.decodeIfPresent([QuoteMessageAttachment].self, forKey: .attachments)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()

        // Metadata is free-form on the server, so it is walked rather than modelled: a shape
        // change must cost the question card, never the whole conversation.
        let metadata = try? c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        questions = Self.questions(in: metadata)
        questionAnswers = Self.answers(in: metadata)
        answeredMessageId = metadata?["answeredMessageId"]?.stringValue
        thinkingDuration = metadata?["thinkingDuration"]?.numberValue
    }

    /// Locally-built messages (the optimistic turn, and the photo-attached echo).
    init(
        id: String,
        senderType: Sender,
        content: String,
        attachments: [QuoteMessageAttachment]? = nil,
        createdAt: Date = Date(),
        questionAnswers: [QuestionAnswer] = [],
        answeredMessageId: String? = nil
    ) {
        self.id = id
        self.senderType = senderType
        self.content = content
        self.attachments = attachments
        self.createdAt = createdAt
        self.questions = []
        self.questionAnswers = questionAnswers
        self.answeredMessageId = answeredMessageId
        self.thinkingDuration = nil
    }

    private static func questions(in metadata: JSONValue?) -> [FollowUpQuestion] {
        guard let blocks = metadata?["blocks"]?.arrayValue else { return [] }
        for block in blocks where block["kind"]?.stringValue == "questions" {
            if let raw = block["data"]?["questions"],
               let data = try? JSONEncoder().encode(raw),
               let parsed = try? JSONDecoder().decode([FollowUpQuestion].self, from: data) {
                return parsed
            }
        }
        return []
    }

    private static func answers(in metadata: JSONValue?) -> [QuestionAnswer] {
        guard let raw = metadata?["questionAnswers"],
              let data = try? JSONEncoder().encode(raw),
              let parsed = try? JSONDecoder().decode([QuestionAnswer].self, from: data)
        else { return [] }
        // A value alone is not enough — an answer has to name the question it answers.
        return parsed.filter { !$0.questionId.isEmpty && !$0.value.isEmpty }
    }
}

/// Minimal free-form JSON, so message metadata can be read without modelling a server shape that
/// is explicitly allowed to grow.
indirect enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
}
