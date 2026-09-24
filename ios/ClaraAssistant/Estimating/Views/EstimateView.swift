import SwiftUI

/// Every line item, its price, and every flag, on a screen built for a phone.
///
/// Two rules this file holds to:
///
/// **No arithmetic on money the server already did.** Every `unitPrice` arrives with markup applied
/// and every tax figure comes from the module that feeds the proposal documents. The only sums here
/// are section subtotals — adding `totalPrice` over rows the technician can see — which cannot
/// disagree with the server because they are not competing with it.
///
/// **Options bill alongside the base scope, never instead of it.** Option lines stay out of the
/// Materials and Labor groups and their subtotals: folding an alternative into the materials
/// subtotal shows a figure the customer will never be charged.
struct EstimateView: View {
    let store: QuoteStore

    @State private var openLineId: String?
    @State private var addingTo: AddTarget?
    @State private var showTaxSheet = false
    @State private var chosenOption = ""

    private enum AddTarget: Hashable { case material, labor }

    private var quote: Quote { store.quote }
    private var frozen: Bool { quote.isFrozen }

    private func subtotal(_ items: [QuoteLineItem]) -> Double {
        items.reduce(0) { $0 + ($1.totalPrice ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if frozen {
                    Text("This estimate is Completed and frozen — no line item can be added, removed, or edited. Move it back to Draft to make changes.")
                        .font(.footnote.weight(.medium))
                        .listRowBackground(Color.secondary.opacity(0.12))
                } else if quote.blockingFlagCount > 0 {
                    Label(
                        "\(quote.blockingFlagCount) of \(quote.lineItems.count) line item(s) need attention before this estimate can be marked Completed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                }

                customerSection
                if !frozen { markupSection }

                lineSection(
                    title: "Materials",
                    note: quote.markupPercent > 0 ? "includes \(Int(quote.markupPercent))% markup" : nil,
                    items: quote.materials,
                    target: .material,
                    addLabel: "Add material item"
                )

                lineSection(
                    title: "Labor",
                    note: nil,
                    items: quote.labor,
                    target: .labor,
                    addLabel: "Add labor item"
                )

                // One group per alternative. No add button: an option group is authored by the
                // agent, and a hand-added line here would need a name this screen cannot ask for.
                ForEach(quote.optionGroups, id: \.name) { group in
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        sectionHeader(
                            group.name,
                            note: quote.chosenOptionGroup == group.name ? "chosen by the customer" : "alternative",
                            subtotal: subtotal(group.items)
                        )
                    }
                }

                if let options = quote.optionTotals, !options.isEmpty {
                    Section("Option comparison") {
                        ForEach(options) { option in
                            LabeledContent(option.name) {
                                Text(money(option.payable)).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                }

                if !quote.lineItems.isEmpty { taxSection }

                ProjectPhotosSection(store: store)
                syncSection
            }
            .listStyle(.insetGrouped)

            totalsBar
        }
        .sheet(isPresented: $showTaxSheet) {
            TaxRateSheet(
                currentSalesTaxId: quote.salesTaxId,
                currentRatePercent: quote.taxRatePercent,
                taxableSubtotal: quote.taxableSubtotal
            ) { salesTaxId in
                showTaxSheet = false
                Task { await store.setSalesTax(id: salesTaxId) }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var customerSection: some View {
        Section("Customer") {
            CustomerRow(store: store)
        }
    }

    private var markupSection: some View {
        Section {
            // Commits as typed; the server re-prices every material line on the response, so no
            // client-side math happens here.
            CommitField(
                label: "Markup",
                caption: "Materials only",
                value: String(format: "%g", quote.markupPercent),
                suffix: "%",
                disabled: store.isBusy
            ) { text in
                guard let value = Double(text.replacingOccurrences(of: "%", with: "")) else { return }
                Task { await store.setMarkup(value) }
            }
        }
    }

    private func lineSection(
        title: String,
        note: String?,
        items: [QuoteLineItem],
        target: AddTarget,
        addLabel: String
    ) -> some View {
        Section {
            ForEach(items) { row($0) }

            if !frozen {
                if addingTo == target {
                    AddLineForm(isLabor: target == .labor, busy: store.isBusy) { draft in
                        addingTo = nil
                        guard let draft else { return }
                        Task {
                            await store.addItem(
                                description: draft.description,
                                quantity: draft.quantity,
                                unit: draft.unit,
                                unitPrice: draft.unitPrice,
                                isLabor: target == .labor
                            )
                        }
                    }
                } else if addingTo == nil {
                    // Suppressed while the other section's form is open: one slot, so tapping
                    // across would silently discard a half-filled line.
                    Button(addLabel, systemImage: "plus.circle") { addingTo = target }
                        .font(.subheadline)
                }
            }
        } header: {
            sectionHeader(title, note: note, subtotal: items.isEmpty ? nil : subtotal(items))
        }
    }

    private func sectionHeader(_ title: String, note: String?, subtotal: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if let note {
                Text("· \(note)").font(.caption2).foregroundStyle(.secondary).textCase(nil)
            }
            Spacer()
            if let subtotal {
                Text(money(subtotal)).monospacedDigit()
            }
        }
    }

    private func row(_ item: QuoteLineItem) -> some View {
        LineItemRow(
            item: item,
            allItems: quote.lineItems,
            isOpen: openLineId == item.id,
            frozen: frozen,
            busy: store.isBusy,
            searching: store.searchingItemIds.contains(item.id),
            qboItems: store.qboItems,
            onToggle: { openLineId = openLineId == item.id ? nil : item.id },
            store: store
        )
    }

    private var taxSection: some View {
        Section {
            Button { if !frozen { showTaxSheet = true } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sales tax").foregroundStyle(.primary)
                        // Nil and 0 mean different things: nil is "no rate configured, show no tax
                        // line at all", 0 is a deliberate zero that still prints.
                        Text(quote.taxRatePercent.map { "\($0.formatted())% of \(money(quote.taxableSubtotal))" }
                             ?? "No rate — this estimate is untaxed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(money(quote.taxAmount)).monospacedDigit().foregroundStyle(.secondary)
                    if !frozen { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(.plain)
            .disabled(frozen)
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        if quote.qboSyncError != nil || quote.ztSyncError != nil || quote.qboEstimateId != nil {
            Section("QuickBooks") {
                if let error = quote.qboSyncError {
                    Label(error, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let id = quote.qboEstimateId {
                    LabeledContent("Estimate", value: id)
                        .font(.footnote)
                    if let at = quote.qboSyncedAt {
                        LabeledContent("Synced", value: at.formatted(.relative(presentation: .named)))
                            .font(.footnote)
                    }
                }
                if let error = quote.ztSyncError {
                    Label("ZenTrades: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Totals

    private var totalsBar: some View {
        VStack(spacing: 10) {
            if let options = store.optionPrompt, !options.isEmpty {
                optionPrompt(options)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                    Text(money(quote.totalWithTax ?? quote.total))
                        .font(.title3.bold())
                        .monospacedDigit()
                }
                Spacer()

                if frozen {
                    Button("Move back to Draft") { Task { await store.reopen() } }
                        .buttonStyle(.bordered)
                        .disabled(store.isBusy)
                } else {
                    Button("Mark as completed") { Task { await store.complete() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy || quote.blockingFlagCount > 0 || store.optionPrompt != nil)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func optionPrompt(_ options: [QuoteOptionTotal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This estimate offers alternatives — which option did the customer choose?")
                .font(.subheadline.weight(.medium))

            ForEach(options) { option in
                Button {
                    chosenOption = option.name
                } label: {
                    HStack {
                        Image(systemName: chosenOption == option.name ? "largecircle.fill.circle" : "circle")
                        Text("\(option.name) — \(money(option.payable)) total")
                        Spacer()
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }

            HStack {
                Button("Confirm & complete") {
                    Task { await store.complete(chosenOption: chosenOption) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosenOption.isEmpty || store.isBusy)

                Button("Cancel") { store.optionPrompt = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { if chosenOption.isEmpty { chosenOption = options.first?.name ?? "" } }
    }
}

/// The customer this estimate bills to.
private struct CustomerRow: View {
    let store: QuoteStore

    @State private var showPicker = false

    var body: some View {
        Button { if !store.quote.isFrozen { showPicker = true } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.quote.customerName ?? "No customer linked")
                        .foregroundStyle(store.quote.customerName == nil ? .secondary : .primary)
                    if let address = store.quote.customerAddress, !address.isEmpty {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                    if let email = store.quote.customerEmail, !email.isEmpty {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !store.quote.isFrozen {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.quote.isFrozen)
        .sheet(isPresented: $showPicker) { CustomerPicker(store: store) }
    }
}
