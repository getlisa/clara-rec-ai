import Foundation

/// Catalog provenance for a line priced from an external source (Home Depot today).
///
/// Render `link` from this field and never from text the model produced — a regenerated product
/// URL can silently corrupt the slug or id.
struct LineItemProduct: Decodable, Hashable {
    let productId: String?
    let link: String?
    let brand: String?
    let rating: Double?
    let packageQuantity: Int?
    /// True until a technician accepts the line this was resolved for.
    let provisional: Bool?
}

struct AmbiguousAction: Decodable, Hashable {
    let action: String
    let candidateItemIds: [String]
    let referenceText: String
}

struct QuoteLineItem: Decodable, Identifiable, Hashable {
    let id: String
    let description: String
    let quantity: Double?
    let unit: String?
    let unitPrice: Double?
    let totalPrice: Double?
    let pricebookCode: String?
    /// Labor is exempt from the quote's markup and seeded non-taxable.
    let isLabor: Bool
    let product: LineItemProduct?
    /// Price came from a live web search, not the catalog — no product id stands behind it.
    let priceEstimated: Bool?
    let estimateLink: String?
    /// Which pricebook priced this, or the Home Depot fallback. Nil for a hand-typed price.
    let priceSource: String?
    let flags: [LineItemFlag]
    let ambiguousAction: AmbiguousAction?
    /// Alternative-option group ("Option A – …"); nil = base scope.
    let optionGroup: String?
    let searchTerm: String?
    let qboItemId: String?
    let qboItemName: String?
    let taxable: Bool?
    let sortOrder: Int

    var isAmbiguous: Bool { flags.contains(.ambiguous) }
    var blockingFlags: [LineItemFlag] { flags.filter(\.isBlocking) }
    /// Labor starts untaxed and materials taxed, matching the "Taxed" column the estimate prints.
    var isTaxable: Bool { taxable ?? !isLabor }
}

struct QuoteOptionTotal: Decodable, Hashable, Identifiable {
    let name: String
    let total: Double
    /// Base scope + this option, BEFORE tax.
    let combinedTotal: Double
    let taxAmount: Double?
    /// What the customer pays for this option, tax included.
    let combinedTotalWithTax: Double?

    var id: String { name }
    var payable: Double { combinedTotalWithTax ?? combinedTotal }
}

struct QuoteImage: Decodable, Identifiable, Hashable {
    let id: String
    let url: String
    let mimeType: String?
    let filename: String?
}

struct Quote: Decodable, Identifiable, Hashable {
    enum Status: String, Decodable { case draft = "DRAFT", completed = "COMPLETED" }

    let id: String
    let conversationId: String
    let status: Status
    let createdAt: Date
    let updatedAt: Date
    let lineItems: [QuoteLineItem]

    /// Materials markup. Every price in `lineItems` already has it applied — never multiply by it
    /// again; it exists here only to fill the Markup field and label the Materials section.
    let markupPercent: Double

    let customerId: Int?
    let customerName: String?
    let customerAddress: String?
    let customerPhone: String?
    let customerEmail: String?

    /// Base scope, BEFORE tax.
    let total: Double
    /// **Nil and 0 mean different things**: nil is "no rate configured, show no tax line at all",
    /// 0 is a deliberate zero that still prints.
    let taxRatePercent: Double?
    let salesTaxId: Int?
    let taxableSubtotal: Double?
    let taxAmount: Double?
    let totalWithTax: Double?
    let optionTotals: [QuoteOptionTotal]?
    let chosenOptionGroup: String?

    let qboEstimateId: String?
    let qboSyncedAt: Date?
    let qboSyncError: String?
    let ztTicketId: String?
    let ztEstimateId: String?
    let ztSyncedAt: Date?
    let ztSyncError: String?

    let blockingFlagCount: Int

    var isFrozen: Bool { status == .completed }

    /// "<customer> : <date time>" once a name is captured, else the date alone.
    var title: String {
        let when = createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let name = customerName, !name.isEmpty else { return when }
        return "\(name) : \(when)"
    }

    /// Base scope is everything not offered as an alternative.
    var materials: [QuoteLineItem] {
        lineItems.filter { $0.optionGroup == nil && !$0.isLabor }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var labor: [QuoteLineItem] {
        lineItems.filter { $0.optionGroup == nil && $0.isLabor }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// One group per alternative, in first-seen order.
    var optionGroups: [(name: String, items: [QuoteLineItem])] {
        var order: [String] = []
        var grouped: [String: [QuoteLineItem]] = [:]
        for item in lineItems {
            guard let group = item.optionGroup else { continue }
            if grouped[group] == nil { order.append(group) }
            grouped[group, default: []].append(item)
        }
        return order.map { ($0, grouped[$0]!.sorted { $0.sortOrder < $1.sortOrder }) }
    }
}

struct QuoteWithMessages: Decodable {
    let quote: Quote
    let messages: [QuoteMessage]

    /// The server returns one flat object: the quote's own fields plus `messages`.
    init(from decoder: Decoder) throws {
        quote = try Quote(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? container.decode([QuoteMessage].self, forKey: .messages)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case messages }
}

/// Currency for display. The server owns every figure here; this only formats it.
func money(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
}
