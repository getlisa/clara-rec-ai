import Foundation

/// Why a line needs attention.
///
/// Deliberately NOT an exhaustive enum. The server derives flags per request and can ship a new key
/// before this app learns it — a strict `Decodable` enum would throw on the whole quote the day
/// that happens. An unrecognised flag is treated as **blocking** and labelled with its raw key,
/// matching the web client: the alternative is a disabled "Mark as completed" with nothing on
/// screen explaining why.
struct LineItemFlag: RawRepresentable, Decodable, Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    static let missingQuantity = LineItemFlag(rawValue: "missing_quantity")
    static let unmatched = LineItemFlag(rawValue: "unmatched")
    static let ambiguous = LineItemFlag(rawValue: "ambiguous")
    static let agentSuggested = LineItemFlag(rawValue: "agent_suggested")
    static let estimatedPrice = LineItemFlag(rawValue: "estimated_price")
    static let manuallyEdited = LineItemFlag(rawValue: "manually_edited")

    /// The only flag that does not gate completion.
    private static let nonBlocking: Set<LineItemFlag> = [.manuallyEdited]

    var isBlocking: Bool { !Self.nonBlocking.contains(self) }

    var label: String {
        switch self {
        case .missingQuantity: return "Missing Qty"
        case .unmatched: return "Unmatched / Unpriced"
        case .ambiguous: return "Ambiguous"
        case .agentSuggested: return "Agent-Suggested · Unconfirmed"
        case .estimatedPrice: return "Estimated Price · Unconfirmed"
        case .manuallyEdited: return "Manually Edited"
        default: return rawValue
        }
    }

    /// What the technician has to do about it — shown in the expanded row.
    var guidance: String? {
        switch self {
        case .missingQuantity:
            return "Enter a quantity above — same effect as if it had been spoken."
        case .unmatched:
            return "No catalog price found — edit the description to a product name (it searches again automatically), type a price, or remove it. No price was guessed."
        case .estimatedPrice:
            return "This price came from a web search, so it needs confirming before the estimate can be completed — type the price you want (it has to differ from the one shown), or remove the line."
        case .agentSuggested:
            return "Proposed from the knowledge base — you didn't name this yourself."
        default:
            return nil
        }
    }
}
