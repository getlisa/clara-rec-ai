import Foundation
import Observation
import Photos

/// Owns one quote and every write against it.
///
/// **Writes never overlap.** There is no optimistic locking server-side and most mutations return a
/// whole-quote snapshot, so two in flight at once means the later response silently discards the
/// earlier one. The client not overlapping its own writes is the entire mitigation — which is why
/// everything goes through `run`.
@MainActor
@Observable
final class QuoteStore {
    private(set) var quote: Quote
    private(set) var messages: [QuoteMessage]
    private(set) var images: [QuoteImage] = []
    private(set) var qboItems: [QboItem]?
    private(set) var isBusy = false
    private(set) var isSending = false
    /// Lines whose catalog search is running, for the per-row spinner.
    private(set) var searchingItemIds: Set<String> = []
    /// Why a line could not be priced, keyed by item id.
    ///
    /// The price endpoint answers 404 for "no catalog match" as well as for a missing item, and
    /// the body carries a specific instruction — which size/part wording to use, or that the
    /// catalog price is per EA and cannot price a line measured in FT. Discarding that leaves the
    /// technician staring at "Unmatched / Unpriced" with only generic advice.
    private(set) var priceFailures: [String: String] = [:]
    var errorMessage: String?

    /// Set when completion 409s with OPTION_CHOICE_REQUIRED.
    var optionPrompt: [QuoteOptionTotal]?

    /// What each agent turn did to the estimate, keyed by the reply's message id.
    ///
    /// The agent's whole job is turning speech into line items, and the reply text rarely spells
    /// out what actually landed — so the conversation shows it: "Added 3 items · Total $1,240.50".
    /// Derived by diffing the quote across the turn, never by trusting a narration.
    private(set) var turnChanges: [String: TurnChange] = [:]

    /// On: a photo taken with the glasses' own button lands on this quote by itself.
    private(set) var isAutoImportOn = false
    /// Set when auto-import cannot start, e.g. the Meta AI app has never imported a photo here.
    var autoImportProblem: String?

    private let watcher = GlassesPhotoWatcher()
    private let api: QuotesAPI
    private let companies: CompaniesAPI
    /// Lines already auto-searched this session, so a no-match doesn't retrigger every render.
    private var autoSearched: Set<String> = []

    init(
        quote: Quote,
        messages: [QuoteMessage],
        api: QuotesAPI = QuotesAPI(),
        companies: CompaniesAPI = CompaniesAPI()
    ) {
        self.quote = quote
        self.messages = messages
        self.api = api
        self.companies = companies
    }

    /// A turn's effect on the estimate. `newTotal` is the server's figure, never recomputed.
    struct TurnChange: Equatable {
        var added = 0
        var removed = 0
        var changed = 0
        var newTotal: Double = 0
        var totalDelta: Double = 0

        var isEmpty: Bool { added == 0 && removed == 0 && changed == 0 }

        /// "Added 3 items", "Updated 2 items", "Added 1 · removed 2" — whatever actually happened.
        var summary: String {
            var parts: [String] = []
            if added > 0 { parts.append("Added \(added) item\(added == 1 ? "" : "s")") }
            if removed > 0 { parts.append("removed \(removed)") }
            if changed > 0 { parts.append("updated \(changed)") }
            return parts.joined(separator: " · ")
        }
    }

    private static func diff(from before: Quote, to after: Quote) -> TurnChange {
        let beforeById = Dictionary(uniqueKeysWithValues: before.lineItems.map { ($0.id, $0) })
        let afterById = Dictionary(uniqueKeysWithValues: after.lineItems.map { ($0.id, $0) })

        let added = afterById.keys.filter { beforeById[$0] == nil }.count
        let removed = beforeById.keys.filter { afterById[$0] == nil }.count
        let changed = afterById.compactMap { id, item -> Bool? in
            guard let old = beforeById[id] else { return nil }
            return old.quantity != item.quantity
                || old.totalPrice != item.totalPrice
                || old.description != item.description
        }.filter { $0 }.count

        return TurnChange(
            added: added,
            removed: removed,
            changed: changed,
            newTotal: after.totalWithTax ?? after.total,
            totalDelta: (after.totalWithTax ?? after.total) - (before.totalWithTax ?? before.total)
        )
    }

    var visibleMessages: [QuoteMessage] { messages.filter { !$0.isAnswerEcho } }

    /// Answers submitted against an earlier question card, keyed by that card's message id, so the
    /// card can show its own selection.
    var answersByCard: [String: [QuestionAnswer]] {
        var result: [String: [QuestionAnswer]] = [:]
        for message in messages {
            if let card = message.answeredMessageId, !message.questionAnswers.isEmpty {
                result[card] = message.questionAnswers
            }
        }
        return result
    }

    // MARK: - Loading

    func loadSupporting() async {
        async let images = try? api.images(quote.id)
        async let items = try? companies.qboItems()
        self.images = await images ?? []
        // Nil means not connected or unavailable — the per-line picker then simply doesn't render.
        self.qboItems = await items
    }

    func refresh() async {
        guard let fresh = try? await api.get(quote.id) else { return }
        quote = fresh.quote
        messages = fresh.messages
    }

    // MARK: - Writes

    /// Serialises every mutation and replaces the whole quote from the response.
    private func run(_ operation: () async throws -> Quote) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            quote = try await operation()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Diag.log("quote", "error: \(errorMessage ?? "?")")
    }

    func setMarkup(_ percent: Double) async {
        await run { try await api.update(quote.id, markupPercent: percent) }
    }

    func setCustomer(id: Int?) async {
        await run { try await api.update(quote.id, customerId: .some(id)) }
    }

    func setSalesTax(id: Int?) async {
        await run { try await api.update(quote.id, salesTaxId: .some(id)) }
    }

    func patchItem(
        _ itemId: String,
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
    ) async {
        // A reworded description deserves a fresh catalog search — and a fresh verdict.
        autoSearched.remove(itemId)
        priceFailures[itemId] = nil
        await run {
            try await api.updateItem(
                quote.id, itemId: itemId, description: description, quantity: quantity,
                unit: unit, unitPrice: unitPrice, totalPrice: totalPrice, taxable: taxable,
                confirm: confirm, resolveCandidateId: resolveCandidateId,
                qboItemId: qboItemId, qboItemName: qboItemName
            )
        }
    }

    func removeItem(_ itemId: String) async {
        await run { try await api.removeItem(quote.id, itemId: itemId) }
    }

    func addItem(description: String, quantity: Double?, unit: String?, unitPrice: Double?, isLabor: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.addItem(
                quote.id, description: description, quantity: quantity,
                unit: unit, unitPrice: unitPrice, isLabor: isLabor
            )
            // addItem answers with the line, not the quote — and adding one re-prices the rest.
            await refresh()
        } catch {
            report(error)
        }
    }

    func reopen() async {
        await run { try await api.reopen(quote.id) }
    }

    /// Completes, answering the option question when the server asks it.
    func complete(chosenOption: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            quote = try await api.complete(quote.id, chosenOption: chosenOption)
            optionPrompt = nil
        } catch let error as APIError {
            switch error.code {
            case "OPTION_CHOICE_REQUIRED":
                // The options ride on the error; the prompt sends the choice on the retry.
                optionPrompt = quote.optionTotals
                errorMessage = error.errorDescription
            case "TAX_RATE_UNAVAILABLE":
                // The snapshotted rate lost its TaxCode in the connected file. The fix is picking
                // another, so the message is shown as-is rather than replaced.
                errorMessage = error.errorDescription
            default:
                report(error)
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Catalog search

    /// Unpriced lines search for themselves — all at once, no button; the server's semaphore
    /// paces them. Failures stay silent: the "Unmatched" flag remains visible and the backend's
    /// own retry ledger keeps trying on later agent turns.
    func autoPriceUnmatched() async {
        guard !quote.isFrozen, searchingItemIds.isEmpty else { return }
        let targets = quote.lineItems.filter {
            $0.flags.contains(.unmatched) && !autoSearched.contains($0.id)
        }
        guard !targets.isEmpty else { return }

        targets.forEach { autoSearched.insert($0.id) }
        searchingItemIds = Set(targets.map(\.id))
        Diag.log("quote", "auto-pricing \(targets.count) unmatched line(s)")

        await withTaskGroup(of: (String, String?).self) { group in
            for target in targets {
                group.addTask { [api, quote] in
                    do {
                        _ = try await api.priceItem(quote.id, itemId: target.id)
                        return (target.id, nil)
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        return (target.id, reason)
                    }
                }
            }
            for await (itemId, reason) in group {
                if let reason {
                    priceFailures[itemId] = reason
                    Diag.log("quote", "could not price \(itemId): \(reason)")
                } else {
                    priceFailures[itemId] = nil
                }
            }
        }

        // Concurrent responses each carry a snapshot from a different moment, and the last to
        // arrive isn't guaranteed to be the freshest — one read settles it.
        searchingItemIds = []
        await refresh()
    }

    func priceItem(_ itemId: String) async {
        searchingItemIds.insert(itemId)
        defer { searchingItemIds.remove(itemId) }
        do {
            quote = try await api.priceItem(quote.id, itemId: itemId)
            priceFailures[itemId] = nil
        } catch {
            priceFailures[itemId] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            report(error)
        }
    }

    // MARK: - Chat

    func send(content: String, answers: [QuestionAnswer] = [], answeredMessageId: String? = nil) async {
        guard !isSending, !quote.isFrozen else { return }
        isSending = true
        defer { isSending = false }

        // The optimistic turn carries the answer metadata too, so a question card locks and shows
        // its selection immediately — and the raw question/answer text never flashes as a bubble.
        let localId = "local-\(Date().timeIntervalSince1970)"
        messages.append(
            QuoteMessage(
                id: localId, senderType: .user, content: content,
                questionAnswers: answers, answeredMessageId: answeredMessageId
            )
        )

        let before = quote
        do {
            let result = try await api.sendMessage(
                quote.id, content: content, answers: answers, answeredMessageId: answeredMessageId
            )
            messages.removeAll { $0.id == localId }
            messages.append(contentsOf: [result.reply])
            quote = result.quote

            let change = Self.diff(from: before, to: result.quote)
            if !change.isEmpty {
                turnChanges[result.reply.id] = change
                Diag.log("quote", "turn changed the estimate: \(change.summary)")
            }
            // The server persisted the user turn too; re-read so history matches exactly.
            await refresh()
        } catch {
            // Drop the optimistic turn: leaving it keeps a question card locked on answers the
            // server never received, with no way to retry.
            messages.removeAll { $0.id == localId }
            report(error)
        }
    }

    // MARK: - Hands-free import

    /// Auto-import photos taken with the button on the glasses.
    ///
    /// Deliberately explicit and per-quote: silently watching a photo library and uploading to a
    /// customer record is not something to leave running unannounced, and the technician needs to
    /// decide which quote a walk-around belongs to.
    func setAutoImport(_ on: Bool, announceProblems: Bool = true) {
        guard on else {
            // A deliberate switch-off forgets everything: the next switch-on starts clean rather
            // than back-filling whatever arrived while it was off.
            watcher.stop()
            isAutoImportOn = false
            return
        }
        guard !quote.isFrozen else { return }

        let started = watcher.start { [weak self] assets in
            guard let self else { return }
            Task { await self.importFromLibrary(assets) }
        }

        if started {
            isAutoImportOn = true
            autoImportProblem = nil
        } else {
            isAutoImportOn = false
            // Silent when this was the automatic start: someone who has never used the glasses
            // with this phone should not meet a warning on every estimate they open.
            autoImportProblem = announceProblems
                ? "No glasses photos have synced to this phone yet. Open the Meta AI app once so it creates its album, then try again."
                : nil
        }
    }

    /// Pause watching when the Estimate tab goes away — switching to Chat, or leaving the quote.
    ///
    /// History is kept, because this store lives exactly as long as the quote screen does: a
    /// glance at the Chat tab must not make the app forget that a photo taken thirty seconds ago
    /// belongs on this estimate. Leaving the quote releases the store, and the history with it.
    func stopAutoImport() {
        watcher.stop(keepingHistory: true)
        isAutoImportOn = false
    }

    private func importFromLibrary(_ assets: [PHAsset]) async {
        guard !quote.isFrozen else { return }
        var jpegs: [Data] = []
        for asset in assets {
            // Full-size original with orientation baked in; may pull from iCloud.
            if let data = await PhotoLibraryImport.jpeg(for: asset) { jpegs.append(data) }
        }
        guard !jpegs.isEmpty else { return }
        Diag.log("watch", "auto-importing \(jpegs.count) photo(s) onto the quote")
        await attachPhotos(jpegs)
    }

    // MARK: - Photos

    /// Attaches photos to the quote — they never reach the agent, and show up in the proposal's
    /// PROJECT PHOTOS section.
    func attachPhotos(_ jpegs: [Data]) async {
        guard !jpegs.isEmpty, !quote.isFrozen else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Orientation is baked into the pixels first: the server stores JPEGs byte-for-byte
            // and the document builders ignore the EXIF tag, so a tagged photo prints sideways.
            let upright = jpegs.map { JPEGOrientation.normalized($0) }
            var latest: [QuoteImage] = images
            for batch in stride(from: 0, to: upright.count, by: MultipartBody.maxFiles).map({
                Array(upright[$0..<min($0 + MultipartBody.maxFiles, upright.count)])
            }) {
                latest = try await api.uploadImages(quote.id, jpegs: batch)
            }
            images = latest

            // The server persists a USER message for the attachment too, but only a refetch would
            // show it — so the timeline gets a local copy immediately. Without this, attaching a
            // photo from the chat composer looks like nothing happened at all.
            let attached = Array(latest.suffix(upright.count))
            messages.append(
                QuoteMessage(
                    id: "local-photo-\(Date().timeIntervalSince1970)",
                    senderType: .user,
                    content: upright.count == 1
                        ? "Photo attached to the quote"
                        : "\(upright.count) photos attached to the quote",
                    attachments: attached.map {
                        QuoteMessageAttachment(id: $0.id, url: $0.url, type: $0.mimeType, filename: $0.filename)
                    }
                )
            )

            Diag.log("quote", "attached \(upright.count) photo(s), \(images.count) total")
            if let first = latest.first, let parsed = URL(string: first.url) {
                // Host and path only — the query string carries the S3 signature.
                Diag.log("quote", "image url: \(parsed.scheme ?? "?")://\(parsed.host ?? "?")\(parsed.path)")
            } else if let first = latest.first {
                Diag.log("quote", "image url is not parseable: \(first.url.prefix(80))")
            }
        } catch {
            report(error)
        }
    }

    func removeImage(_ imageId: String) async {
        do { images = try await api.removeImage(quote.id, imageId: imageId) } catch { report(error) }
    }
}
