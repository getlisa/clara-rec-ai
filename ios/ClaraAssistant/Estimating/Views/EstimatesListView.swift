import SwiftUI

/// One chat = one quote. The home for all estimates, named by customer and creation time,
/// defaulting to Drafts.
struct EstimatesListView: View {
    @State private var status: Quote.Status = .draft
    @State private var quotes: [Quote] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var connections: ConnectionsStatus?
    @State private var showZtPicker = false
    @State private var newQuote: Quote?

    private let api = QuotesAPI()
    private let companies = CompaniesAPI()

    var body: some View {
        List {
            Picker("Status", selection: $status) {
                Text("Draft").tag(Quote.Status.draft)
                Text("Completed").tag(Quote.Status.completed)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if quotes.isEmpty {
                ContentUnavailableView(
                    status == .draft ? "No drafts yet" : "No completed estimates",
                    systemImage: "doc.text",
                    description: Text(
                        status == .draft
                            ? "Start a new estimate and talk through the job to capture it."
                            : "Estimates you mark as completed appear here."
                    )
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(quotes) { quote in
                    NavigationLink(value: quote) { QuoteRow(quote: quote) }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Estimates")
        .navigationDestination(for: Quote.self) { QuoteDetailView(quoteId: $0.id) }
        .navigationDestination(item: $newQuote) { QuoteDetailView(quoteId: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isCreating {
                    ProgressView()
                } else if connections?.isZtConnected == true {
                    // With ZenTrades linked, New becomes a two-path chooser. Companies without a
                    // connection see the plain button, unchanged.
                    Menu {
                        Button("Blank estimate", systemImage: "message") { create() }
                        Button("From ZenTrades job", systemImage: "wrench.and.screwdriver") {
                            showZtPicker = true
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                } else {
                    Button { create() } label: { Label("New", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $showZtPicker) {
            ZenTradesJobPicker { job in
                showZtPicker = false
                create(ztTicketId: job.ztTicketId)
            }
        }
        .refreshable { await load() }
        .task(id: status) { await load() }
        .task {
            // Cheap and cached: decides whether New is a button or a chooser.
            connections = try? await companies.connections()
        }
    }

    private func load() async {
        isLoading = quotes.isEmpty
        errorMessage = nil
        do {
            quotes = try await api.list(status: status)
            Diag.log("quote", "listed \(quotes.count) \(status.rawValue) quote(s)")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func create(ztTicketId: String? = nil) {
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                newQuote = try await api.create(ztTicketId: ztTicketId)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct QuoteRow: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quote.title).font(.headline).lineLimit(1)
                Spacer()
                StatusBadge(status: quote.status)
            }

            HStack(spacing: 8) {
                Text("Updated \(quote.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if quote.status == .draft, quote.blockingFlagCount > 0 {
                    Text("· \(quote.blockingFlagCount) need attention")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            if let ticket = quote.ztTicketId {
                Label("ZT \(ticket)", systemImage: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: Quote.Status

    var body: some View {
        Text(status == .completed ? "Completed" : "Draft")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                status == .completed ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.16),
                in: Capsule()
            )
            .foregroundStyle(status == .completed ? Color.accentColor : .secondary)
    }
}

/// Picks a synced ZenTrades job to seed a new estimate from.
private struct ZenTradesJobPicker: View {
    let onPick: (ZtJob) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var jobs: [ZtJob] = []
    @State private var isLoading = true

    private let companies = CompaniesAPI()

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if jobs.isEmpty {
                    ContentUnavailableView(
                        "No ZenTrades jobs",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("Ask an admin to sync jobs from the web app.")
                    )
                } else {
                    ForEach(jobs) { job in
                        Button { onPick(job) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.headline).font(.subheadline.weight(.medium))
                                if !job.subtitle.isEmpty {
                                    Text(job.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                if let open = job.openDeficiencyCount, open > 0 {
                                    Text("\(open) open deficienc\(open == 1 ? "y" : "ies")")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose a job")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Job number, description, or customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: search) {
                isLoading = jobs.isEmpty
                jobs = (try? await companies.ztJobs(search: search)) ?? []
                isLoading = false
            }
        }
    }
}
