import SwiftUI

/// One quote: the conversation that built it, and the estimate it produced.
struct QuoteDetailView: View {
    let quoteId: String

    @State private var store: QuoteStore?
    @State private var tab: Tab = .chat
    @State private var loadError: String?
    @AppStorage(AppSettings.handsFreeCaptureKey) private var handsFree = true

    private enum Tab: Hashable { case chat, estimate }

    private let api = QuotesAPI()

    var body: some View {
        Group {
            if let store {
                VStack(spacing: 0) {
                    Picker("View", selection: $tab) {
                        Text("Chat").tag(Tab.chat)
                        // The blocking count rides on the tab: a technician must never have to go
                        // looking for why they cannot finish.
                        Text(store.quote.blockingFlagCount > 0
                             ? "Estimate (\(store.quote.blockingFlagCount))"
                             : "Estimate")
                            .tag(Tab.estimate)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    Divider()

                    switch tab {
                    case .chat: QuoteChatView(store: store)
                    case .estimate: EstimateView(store: store)
                    }
                }
                .navigationTitle(store.quote.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        DeliveryMenu(store: store)
                    }
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Could not open this estimate",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        // Hands-free belongs to the whole quote, not to one tab. A technician building an estimate
        // is usually in the Chat tab — which is exactly when a photo taken on the glasses arrives,
        // and exactly when it must still be caught.
        .task(id: handsFree) {
            guard let store, handsFree, !store.quote.isFrozen else { return }
            store.setAutoImport(true, announceProblems: false)
        }
        .onDisappear { store?.stopAutoImport() }
    }

    private func load() async {
        guard store == nil else { return }
        do {
            let loaded = try await api.get(quoteId)
            let store = QuoteStore(quote: loaded.quote, messages: loaded.messages)
            self.store = store
            // Started here rather than in a .task on the view: the store does not exist when the
            // screen first appears, so a guard there would simply never fire.
            if handsFree, !store.quote.isFrozen {
                store.setAutoImport(true, announceProblems: false)
            }
            await store.loadSupporting()
            await store.autoPriceUnmatched()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Send / Download, as a menu. Two actions are available in any state — email the proposal, or
/// download it — and QuickBooks/ZenTrades add more when connected.
private struct DeliveryMenu: View {
    let store: QuoteStore

    @State private var connections: ConnectionsStatus?
    @State private var working = false
    @State private var draft: QuotesAPI.EmailDraft?
    @State private var shareItem: ShareFile?
    @State private var message: String?

    private let api = QuotesAPI()
    private let companies = CompaniesAPI()

    private var quote: Quote { store.quote }
    /// Completion is what files an estimate and the server refuses a Draft — and offering a sync
    /// to a company with no integration is an action that can only fail.
    private var canSyncQbo: Bool { connections?.isQboConnected == true && quote.isFrozen }
    private var canSyncZt: Bool {
        connections?.isZtConnected == true && quote.ztTicketId != nil && quote.isFrozen
    }

    var body: some View {
        Menu {
            Button("Send via email", systemImage: "envelope") { openDraft() }
            Button("Download proposal (PDF)", systemImage: "arrow.down.doc") { share(.proposalPDF) }
            Button("Download proposal (.docx)", systemImage: "doc.richtext") { share(.proposalDocx) }
            Button("Download quote (.docx)", systemImage: "doc.text") { share(.quoteDocx) }

            if canSyncQbo || canSyncZt {
                Divider()
                if canSyncQbo {
                    Button(
                        quote.qboEstimateId == nil ? "Sync to QuickBooks" : "Re-sync to QuickBooks",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) { syncQbo() }
                }
                if canSyncZt {
                    Button(
                        quote.ztEstimateId == nil ? "Sync to ZenTrades" : "Re-sync to ZenTrades",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) { syncZt() }
                }
            }
        } label: {
            if working { ProgressView() } else { Label("Send", systemImage: "square.and.arrow.up") }
        }
        .disabled(working)
        .task { connections = try? await companies.connections() }
        .sheet(item: $draft) { current in
            EmailProposalSheet(store: store, draft: current) { message = $0 }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .alert("Estimate", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private enum Document { case proposalPDF, proposalDocx, quoteDocx }

    private func share(_ kind: Document) {
        working = true
        Task {
            defer { working = false }
            do {
                let (data, name): (Data, String) = switch kind {
                case .proposalPDF: (try await api.proposalPDF(quote.id), "Proposal.pdf")
                case .proposalDocx: (try await api.proposalDocx(quote.id), "Proposal.docx")
                case .quoteDocx: (try await api.quoteDocx(quote.id), "Quote.docx")
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                shareItem = ShareFile(url: url)
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func openDraft() {
        working = true
        Task {
            defer { working = false }
            do { draft = try await api.emailDraft(quote.id) } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func syncQbo() {
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await api.syncToQbo(quote.id)
                message = result.updated == true
                    ? "Estimate updated in QuickBooks"
                    : "Estimate sent to QuickBooks"
                // The sync endpoint returns only what it did, not the quote — without a re-read
                // the failure panel keeps saying it never arrived, right after a success message.
                await store.refresh()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func syncZt() {
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await api.syncToZt(quote.id)
                message = "Estimate sent to ZenTrades"
                await store.refresh()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The email review — a form with a document preview, so it stays a sheet rather than a menu item.
private struct EmailProposalSheet: View {
    let store: QuoteStore
    @State var draft: QuotesAPI.EmailDraft
    let onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var error: String?

    private let api = QuotesAPI()

    private var canSend: Bool {
        draft.to.contains("@") && draft.to.contains(".") && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    TextField("Recipient", text: $draft.to)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Subject") { TextField("Subject", text: $draft.subject) }
                Section("Message") {
                    TextEditor(text: $draft.body).frame(minHeight: 200)
                }
                Section {
                    Label("The proposal PDF is attached automatically.", systemImage: "paperclip")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Review email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(!canSend)
                }
            }
        }
    }

    private func send() {
        sending = true
        Task {
            defer { sending = false }
            do {
                let result = try await api.emailProposal(store.quote.id, draft: draft)
                onResult("Proposal sent to \(result.to ?? draft.to)")
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

extension QuotesAPI.EmailDraft: Identifiable {
    public var id: String { subject + to }
}
