import Foundation

/// Which integrations the company has linked. Decides whether the sync actions exist at all —
/// offering a sync into a system nobody connected is an action that can only fail.
struct ConnectionsStatus: Decodable {
    struct Qbo: Decodable {
        let connected: Bool?
        let environment: String?
    }

    struct Zt: Decodable {
        let connected: Bool?
    }

    /// Decided by the SERVER from the role in the verified JWT. Trust this over a local role
    /// check — the login response's role can be missing, which would hide the controls from
    /// admins too, indistinguishably from the feature being broken.
    let canManage: Bool?
    let qbo: Qbo?
    let zt: Zt?

    var isQboConnected: Bool { qbo?.connected == true }
    var isZtConnected: Bool { zt?.connected == true }
}

struct QboItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct QboCustomer: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let email: String?

    var displayName: String { name ?? "Customer \(id)" }

    private enum CodingKeys: String, CodingKey { case id, customerId, name, email }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Search returns `id`; the create endpoint answers with `customerId`.
        id = (try? c.decode(Int.self, forKey: .id))
            ?? (try? c.decode(Int.self, forKey: .customerId))
            ?? 0
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
    }
}

/// What `POST /companies/qbo/customers` answers with.
struct CreatedCustomer: Decodable {
    let customerId: Int
    let name: String?
    /// Parts of the address the server could not infer. Non-empty means ask for them — it never
    /// guesses an address.
    let addressMissing: [String]?
}

/// `GET /companies/sales-tax` answers with settings, not a bare array of rates.
struct SalesTaxSettings: Decodable {
    let taxSource: String?
    /// Absent means **on**.
    let taxEnabled: Bool?
    let taxEnforced: Bool?
    let taxEnforcedBy: String?
    let rates: [SalesTaxRate]?

    var isTaxEnabled: Bool { taxEnabled ?? true }
    /// Only rates that are both active and applicable right now are worth offering.
    var offerableRates: [SalesTaxRate] {
        (rates ?? []).filter { ($0.isActive ?? true) && $0.isUsable }
    }
}

struct ZtJob: Decodable, Identifiable, Hashable {
    let ztTicketId: String
    let ticketNumber: String?
    let jobDescription: String?
    let customerName: String?
    let serviceAddressName: String?
    let scheduledStartTime: Date?
    let openDeficiencyCount: Int?

    var id: String { ztTicketId }
    var headline: String {
        "\(ticketNumber ?? ztTicketId) · \(jobDescription?.isEmpty == false ? jobDescription! : "(no description)")"
    }

    var subtitle: String {
        [customerName, serviceAddressName].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct SalesTaxRate: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// "MANUAL", "QBO", or "ZENTRADES".
    let source: String?
    let ratePercent: Double
    let isDefault: Bool?
    let isActive: Bool?
    /// Whether the rate can be applied right now — computed by the server against the connection
    /// state, so a MANUAL rate is unusable while tax comes from a connected system.
    let usable: Bool?

    var isUsable: Bool { usable ?? true }
}
