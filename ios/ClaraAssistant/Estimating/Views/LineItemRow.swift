import SwiftUI

/// One line item: a compact tappable summary that expands into the full editor.
///
/// Collapsing is what makes a four-line estimate fit on a phone. Its cost is that a row needing
/// attention could hide — and blocking flags are what gate *Mark as completed* — so the summary
/// carries its own blocking badge and an amber edge. A technician must never have to open rows one
/// by one to find out why they cannot finish.
///
/// Every price here already carries the quote's markup: the server applies it on read and strips it
/// back out on write. Nothing on this row multiplies by a markup, and nothing should.
struct LineItemRow: View {
    let item: QuoteLineItem
    let allItems: [QuoteLineItem]
    let isOpen: Bool
    let frozen: Bool
    let busy: Bool
    let searching: Bool
    let qboItems: [QboItem]?
    let onToggle: () -> Void
    let store: QuoteStore

    private var disabled: Bool { frozen || busy }

    private var candidates: [QuoteLineItem] {
        guard let ids = item.ambiguousAction?.candidateItemIds else { return [] }
        return ids.compactMap { id in allItems.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isOpen { editor.padding(.top, 12) }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if !item.blockingFlags.isEmpty {
                Rectangle().fill(.orange).frame(width: 3).padding(.vertical, -6)
            }
        }
        .overlay {
            if searching {
                ZStack {
                    Color(.systemBackground).opacity(0.7)
                    Label("Searching…", systemImage: "magnifyingglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // The dot is decorative; the label carries the meaning — colour alone cannot say
                // Material vs Labor to a screen reader, and inside an option group the section
                // header cannot supply it either.
                Circle()
                    .fill(item.isLabor ? Color.orange : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isAmbiguous
                         ? "\"\(item.ambiguousAction?.referenceText ?? item.description)\""
                         : item.description)
                        .font(.subheadline.weight(.semibold))
                        .italic(item.isAmbiguous)
                        .foregroundStyle(item.isAmbiguous ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if !item.isAmbiguous {
                            Text("\(item.quantity.map { $0.formatted() } ?? "—")\(item.unit.map { " \($0)" } ?? "") × \(money(item.unitPrice))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        // The one thing a collapsed row must never hide: why completion is blocked.
                        if let badge = blockingBadge {
                            Label(badge, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(money(item.totalPrice)).font(.subheadline.weight(.bold)).monospacedDigit()
                    if !item.isTaxable, !item.isAmbiguous {
                        Text("not taxed").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .frame(minHeight: 44)
            .accessibilityLabel(item.isLabor ? "Labor: \(item.description)" : "Material: \(item.description)")
        }
        .buttonStyle(.plain)
    }

    private var blockingBadge: String? {
        let blocking = item.blockingFlags
        guard !blocking.isEmpty else { return nil }
        return blocking.count == 1 ? blocking[0].label : "\(blocking.count) need attention"
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.isAmbiguous {
                // An ambiguous line has no numbers to edit — the agent could not tell which item
                // was meant, so the only useful action is choosing one.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Which item did you mean? Tap to select — this isn't resolved by voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 7) {
                        ForEach(candidates) { candidate in
                            Button(candidate.description) {
                                Task { await store.patchItem(item.id, resolveCandidateId: candidate.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(disabled)
                        }
                    }
                }
            } else {
                // Editable and load-bearing: the "Unmatched" guidance says to reword this to a
                // product name, and committing it clears the auto-search memo so it searches again.
                CommitField(label: "Description", value: item.description, disabled: disabled) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { await store.patchItem(item.id, description: trimmed) }
                }

                HStack(spacing: 10) {
                    CommitField(
                        label: "Qty",
                        value: item.quantity.map { $0.formatted() } ?? "",
                        keyboard: .decimalPad,
                        highlight: item.flags.contains(.missingQuantity),
                        disabled: disabled
                    ) { text in
                        guard let value = Double(text.replacingOccurrences(of: ",", with: "")) else { return }
                        Task { await store.patchItem(item.id, quantity: value) }
                    }

                    CommitField(label: "Unit", value: item.unit ?? "", disabled: disabled) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        Task { await store.patchItem(item.id, unit: .some(trimmed.isEmpty ? nil : trimmed)) }
                    }
                }

                HStack(spacing: 10) {
                    CommitField(
                        label: "Unit price",
                        value: item.unitPrice.map { String(format: "%.2f", $0) } ?? "",
                        keyboard: .decimalPad,
                        highlight: item.flags.contains(.unmatched),
                        disabled: disabled
                    ) { text in
                        guard let value = Double(text.replacingOccurrences(of: "$", with: "")) else { return }
                        Task { await store.patchItem(item.id, unitPrice: value) }
                    }

                    CommitField(
                        label: "Line total",
                        value: item.totalPrice.map { String(format: "%.2f", $0) } ?? "",
                        keyboard: .decimalPad,
                        disabled: disabled
                    ) { text in
                        guard let value = Double(text.replacingOccurrences(of: "$", with: "")) else { return }
                        Task { await store.patchItem(item.id, totalPrice: value) }
                    }
                }

                // A per-line correction for the exceptions the defaults get wrong — a permit fee
                // that isn't taxed, a warranty callout that is.
                Toggle("Taxable", isOn: Binding(
                    get: { item.isTaxable },
                    set: { value in Task { await store.patchItem(item.id, taxable: value) } }
                ))
                .font(.subheadline)
                .disabled(disabled)

                if let qboItems, !qboItems.isEmpty {
                    Picker("QuickBooks item", selection: Binding(
                        get: { item.qboItemId ?? "" },
                        set: { id in
                            let picked = qboItems.first { $0.id == id }
                            Task {
                                await store.patchItem(
                                    item.id,
                                    qboItemId: .some(picked?.id),
                                    qboItemName: .some(picked?.name)
                                )
                            }
                        }
                    )) {
                        Text("Auto — match or create").tag("")
                        ForEach(qboItems) { Text($0.name).tag($0.id) }
                    }
                    .font(.subheadline)
                    .disabled(disabled)
                }

                provenance
            }

            if !frozen {
                Button("Remove item", systemImage: "trash", role: .destructive) {
                    Task { await store.removeItem(item.id) }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(busy)
            }
        }
    }

    /// Where this line's price came from, and what to do about it. Every branch exists because the
    /// alternative was a price that looked verified when it was not.
    @ViewBuilder
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A web-search estimate is NOT a catalog price — no product id stands behind it — so
            // it is rendered as its own thing and blocks completion until confirmed.
            if item.priceEstimated == true {
                HStack(spacing: 6) {
                    Text("estimated price — not catalog verified")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                    if let link = item.estimateLink, let url = URL(string: link) {
                        Link(link.contains("/p/") ? "View on Home Depot" : "Search Home Depot", destination: url)
                            .font(.caption2)
                    }
                }
            }

            if let source = item.priceSource, !source.isEmpty {
                Text("Price source: \(source.replacingOccurrences(of: " — online fallback", with: ""))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // The href comes from the structured product link, never from model-generated text.
            if let link = item.product?.link, let url = URL(string: link) {
                HStack(spacing: 8) {
                    Link("View on Home Depot", destination: url).font(.caption2)
                    if let brand = item.product?.brand {
                        Text(brand).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let rating = item.product?.rating {
                        Text("★ \(rating, specifier: "%.1f")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let pack = item.product?.packageQuantity, pack > 1 {
                    Text("sold in packs of \(pack) — price is per unit, quantity rounded to whole packs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // The server's own reason beats the generic flag text: it names the wording to use,
            // or the unit mismatch that makes the catalog price inapplicable.
            if let reason = store.priceFailures[item.id], !frozen {
                Label(reason, systemImage: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                ForEach(item.blockingFlags) { flag in
                    if let guidance = flag.guidance, !frozen {
                        Text(guidance).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if item.flags.contains(.agentSuggested), !frozen {
                Button("Confirm") { Task { await store.patchItem(item.id, confirm: true) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
            }

            if item.flags.contains(.unmatched), !searching, !frozen {
                Button("Search catalog again", systemImage: "magnifyingglass") {
                    Task { await store.priceItem(item.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
            }
        }
    }
}

/// A field that commits on blur, and only when the value actually changed.
///
/// That last part is load-bearing: clearing `estimated_price` requires a price *different* from
/// the one shown, so re-committing the same number must do nothing.
struct CommitField: View {
    let label: String
    var caption: String?
    let value: String
    var suffix: String?
    var keyboard: UIKeyboardType = .default
    var highlight = false
    var disabled = false
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if let caption {
                    Text("· \(caption)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 4) {
                TextField(label, text: $text)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(keyboard == .decimalPad)
                    .focused($focused)
                    .disabled(disabled)
                if let suffix { Text(suffix).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(highlight ? Color.orange : .clear, lineWidth: 1)
                    )
            )
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != value else { return }
            onCommit(trimmed)
        }
    }
}

/// Adds one line to a section. The section it belongs to decides `isLabor`, which the server uses
/// to exempt it from markup and seed it non-taxable.
struct AddLineForm: View {
    let isLabor: Bool
    let busy: Bool
    let onFinish: (Draft?) -> Void

    struct Draft {
        let description: String
        let quantity: Double?
        let unit: String?
        let unitPrice: Double?
    }

    @State private var description = ""
    @State private var quantity = ""
    @State private var unit = ""
    @State private var unitPrice = ""

    private var canAdd: Bool {
        !description.trimmingCharacters(in: .whitespaces).isEmpty && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(isLabor ? "Labor description" : "Material description", text: $description)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("Qty", text: $quantity)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                TextField(isLabor ? "HR" : "EA", text: $unit)
                    .textFieldStyle(.roundedBorder)
                TextField("Unit price", text: $unitPrice)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Add") {
                    onFinish(Draft(
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                        quantity: Double(quantity),
                        unit: unit.isEmpty ? nil : unit,
                        unitPrice: Double(unitPrice.replacingOccurrences(of: "$", with: ""))
                    ))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdd)

                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
