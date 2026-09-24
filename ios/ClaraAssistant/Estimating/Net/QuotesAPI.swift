import Foundation

/// The Estimating Agent's full surface — `/api/v1/quotes`, auth'd and scoped to the technician.
///
/// A one-for-one port of the web client's `quotesService`, so the two stay comparable when either
/// changes. Most mutations return the whole quote; callers replace their copy rather than merging.
struct QuotesAPI {
    private let client: CopilotClient
    private let root = "api/v1/quotes"

    init(client: CopilotClient = CopilotClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// `ztTicketId` links the estimate to a synced ZenTrades job — the chat opens pre-seeded.
    func create(ztTicketId: String? = nil) async throws -> Quote {
        struct Body: Encodable { let ztTicketId: String? }
        return try await client.post(root, json: Body(ztTicketId: ztTicketId))
    }

    func list(status: Quote.Status) async throws -> [Quote] {
        try await client.get(root, query: [URLQueryItem(name: "status", value: status.rawValue)])
    }

    func get(_ quoteId: String) async throws -> QuoteWithMessages {
        try await client.get("\(root)/\(quoteId)")
    }

    /// Quote-level fields. Draft only — the server 409s on a completed quote.
    func update(
        _ quoteId: String,
        markupPercent: Double? = nil,
        customerName: String?? = nil,
        customerAddress: String?? = nil,
        customerPhone: String?? = nil,
        customerId: Int?? = nil,
        salesTaxId: Int?? = nil
    ) async throws -> Quote {
        var body: [String: JSONValue] = [:]
        if let markupPercent { body["markupPercent"] = .number(markupPercent) }
        if let customerName { body["customerName"] = customerName.map(JSONValue.string) ?? .null }
        if let customerAddress { body["customerAddress"] = customerAddress.map(JSONValue.string) ?? .null }
        if let customerPhone { body["customerPhone"] = customerPhone.map(JSONValue.string) ?? .null }
        if let customerId { body["customerId"] = customerId.map { .number(Double($0)) } ?? .null }
        // `null` marks the job deliberately UNTAXED, which the server records as a decision — so
        // completing does not helpfully put the company default back on a job someone exempted.
        if let salesTaxId { body["salesTaxId"] = salesTaxId.map { .number(Double($0)) } ?? .null }
        return try await client.patch("\(root)/\(quoteId)", json: body)
    }

    /// A quote with either/or options 409s with `OPTION_CHOICE_REQUIRED` until `chosenOption`
    /// names the option the customer picked.
    func complete(_ quoteId: String, chosenOption: String? = nil) async throws -> Quote {
        struct Body: Encodable { let chosenOption: String? }
        return try await client.post("\(root)/\(quoteId)/complete", json: Body(chosenOption: chosenOption))
    }

    func reopen(_ quoteId: String) async throws -> Quote {
        try await client.post("\(root)/\(quoteId)/reopen")
    }

    // MARK: - The agent turn

    struct SendMessageResult: Decodable {
        let reply: QuoteMessage
        let quote: Quote
    }

    func sendMessage(
        _ quoteId: String,
        content: String,
        imageUrls: [String] = [],
        answers: [QuestionAnswer] = [],
        answeredMessageId: String? = nil
    ) async throws -> SendMessageResult {
        struct Body: Encodable {
            let content: String
            let imageUrls: [String]?
            let answers: [QuestionAnswer]?
            let answeredMessageId: String?
        }
        // Answers and their card ship together: the server only trusts answers that name an AI
        // turn of this quote.
        let pairing = !answers.isEmpty && answeredMessageId != nil
        return try await client.post(
            "\(root)/\(quoteId)/messages",
            json: Body(
                content: content,
                imageUrls: imageUrls.isEmpty ? nil : imageUrls,
                answers: pairing ? answers : nil,
                answeredMessageId: pairing ? answeredMessageId : nil
            ),
            timeout: CopilotClient.Timeout.agentTurn
        )
    }

    // MARK: - Line items

    func addItem(
        _ quoteId: String,
        description: String,
        quantity: Double?,
        unit: String?,
        unitPrice: Double?,
        isLabor: Bool
    ) async throws -> QuoteLineItem {
        struct Body: Encodable {
            let description: String
            let quantity: Double?
            let unit: String?
            let unitPrice: Double?
            /// Decides two things server-side that a follow-up patch cannot correct without a
            /// second round trip: labor is exempt from markup, and seeded non-taxable.
            let isLabor: Bool
        }
        return try await client.post(
            "\(root)/\(quoteId)/items",
            json: Body(description: description, quantity: quantity, unit: unit,
                       unitPrice: unitPrice, isLabor: isLabor)
        )
    }

    /// Every field optional; `confirm` clears `agent_suggested`, `resolveCandidateId` resolves an
    /// ambiguity. Returns the whole quote because a line edit re-prices its siblings.
    func updateItem(
        _ quoteId: String,
        itemId: String,
        description: String? = nil,
        quantity: Double? = nil,
        unit: String?? = nil,
        unitPrice: Double? = nil,
        totalPrice: Double? = nil,
        taxable: Bool? = nil,
        confirm: Bool? = nil,
        resolveCandidateId: String? = nil,
        qboItemId: String?? = nil,
        qboItemName: String?? = nil
    ) async throws -> Quote {
        var body: [String: JSONValue] = [:]
        if let description { body["description"] = .string(description) }
        if let quantity { body["quantity"] = .number(quantity) }
        if let unit { body["unit"] = unit.map(JSONValue.string) ?? .null }
        if let unitPrice { body["unitPrice"] = .number(unitPrice) }
        if let totalPrice { body["totalPrice"] = .number(totalPrice) }
        if let taxable { body["taxable"] = .bool(taxable) }
        if let confirm { body["confirm"] = .bool(confirm) }
        if let resolveCandidateId { body["resolveCandidateId"] = .string(resolveCandidateId) }
        if let qboItemId { body["qboItemId"] = qboItemId.map(JSONValue.string) ?? .null }
        if let qboItemName { body["qboItemName"] = qboItemName.map(JSONValue.string) ?? .null }
        return try await client.patch("\(root)/\(quoteId)/items/\(itemId)", json: body)
    }

    func removeItem(_ quoteId: String, itemId: String) async throws -> Quote {
        try await client.delete("\(root)/\(quoteId)/items/\(itemId)")
    }

    /// On-demand catalog price search for one line. A cold search runs 15–30s.
    func priceItem(_ quoteId: String, itemId: String) async throws -> Quote {
        try await client.post(
            "\(root)/\(quoteId)/items/\(itemId)/price",
            json: [String: String](),
            timeout: CopilotClient.Timeout.priceSearch
        )
    }

    // MARK: - Photos

    func images(_ quoteId: String) async throws -> [QuoteImage] {
        try await client.get("\(root)/\(quoteId)/images")
    }

    /// Attaches photos to the quote itself — never routed through the chat agent. They appear on
    /// the Estimate tab and in the PROJECT PHOTOS section of the proposal documents.
    ///
    /// The server takes at most 4 files of 8 MB each per request, so callers batch.
    func uploadImages(_ quoteId: String, jpegs: [Data]) async throws -> [QuoteImage] {
        try await client.upload("\(root)/\(quoteId)/images", multipart: .jpegs(jpegs))
    }

    func removeImage(_ quoteId: String, imageId: String) async throws -> [QuoteImage] {
        try await client.delete("\(root)/\(quoteId)/images/\(imageId)")
    }

    // MARK: - Delivery

    struct EmailDraft: Codable {
        var to: String
        var subject: String
        var body: String
    }

    func emailDraft(_ quoteId: String) async throws -> EmailDraft {
        try await client.get("\(root)/\(quoteId)/email-draft")
    }

    struct EmailResult: Decodable { let sent: Bool?; let to: String? }

    func emailProposal(_ quoteId: String, draft: EmailDraft) async throws -> EmailResult {
        try await client.post("\(root)/\(quoteId)/email", json: draft)
    }

    func proposalPDF(_ quoteId: String) async throws -> Data {
        try await client.download("\(root)/\(quoteId)/proposal-pdf")
    }

    func proposalDocx(_ quoteId: String) async throws -> Data {
        try await client.download("\(root)/\(quoteId)/proposal-docx")
    }

    func quoteDocx(_ quoteId: String) async throws -> Data {
        try await client.download("\(root)/\(quoteId)/docx")
    }

    // MARK: - Integrations

    struct QboSyncResult: Decodable { let estimateId: String?; let updated: Bool? }

    /// Completed quotes only — completion is the event that files an estimate, and this re-runs
    /// exactly that: updating the estimate it already has rather than adding a second.
    func syncToQbo(_ quoteId: String) async throws -> QboSyncResult {
        try await client.post("\(root)/\(quoteId)/qbo")
    }

    func syncToZt(_ quoteId: String) async throws -> Quote {
        try await client.post("\(root)/\(quoteId)/zt")
    }
}

/// Company-level reads the estimate screens depend on.
struct CompaniesAPI {
    private let client: CopilotClient
    private let root = "api/v1/companies"

    init(client: CopilotClient = CopilotClient()) {
        self.client = client
    }

    func connections() async throws -> ConnectionsStatus {
        try await client.get("\(root)/connections")
    }

    /// The connected account's item list, for the per-line dropdown. Deliberately not admin-gated
    /// server-side — every viewer of a quote screen needs it.
    func qboItems() async throws -> [QboItem] {
        try await client.get("\(root)/connections/qbo/items")
    }

    /// Clara's own customers — works with or without QuickBooks connected.
    func qboCustomers(search: String? = nil) async throws -> [QboCustomer] {
        try await client.get("\(root)/qbo/customers", query: Self.searchQuery(search))
    }

    /// Creates a customer from the estimate screen. `addressMissing` names the parts the server
    /// could not infer — it never guesses an address.
    func createCustomer(
        name: String,
        email: String?,
        phone: String?,
        address: String?
    ) async throws -> CreatedCustomer {
        struct Body: Encodable {
            let name: String
            let email: String?
            let phone: String?
            let address: String?
        }
        return try await client.post(
            "\(root)/qbo/customers",
            json: Body(
                name: name,
                email: email?.isEmpty == true ? nil : email,
                phone: phone?.isEmpty == true ? nil : phone,
                address: address?.isEmpty == true ? nil : address
            )
        )
    }

    /// Settings, not a bare array — the rates live under `rates`, alongside whether tax is on
    /// for this company at all.
    func salesTaxSettings() async throws -> SalesTaxSettings {
        try await client.get("\(root)/sales-tax")
    }

    func ztJobs(search: String? = nil) async throws -> [ZtJob] {
        try await client.get("\(root)/connections/zt/jobs", query: Self.searchQuery(search))
    }

    /// The search parameter is `q` on both list endpoints.
    private static func searchQuery(_ search: String?) -> [URLQueryItem] {
        guard let search, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return [URLQueryItem(name: "q", value: search)]
    }
}
