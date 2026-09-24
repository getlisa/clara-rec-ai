import SwiftUI

/// The conversation that builds the estimate.
///
/// Laid out as an assistant transcript rather than a messaging thread: the agent's turns run
/// full-width under its mark, the technician's sit in a tinted bubble on the right, and each turn
/// carries what it actually did to the estimate. Clarifying questions render as tappable options
/// with an "Other" box — the agent puts them only in the questions array and never in the reply
/// text, so a client that renders just the bubble leaves a reply that appears to ask nothing.
struct QuoteChatView: View {
    let store: QuoteStore

    @State private var draft = ""
    @State private var controller = GlassesController.shared
    @State private var recorder = VoiceRecorder()
    @State private var isTranscribing = false
    @State private var voiceError: String?
    @State private var turnStartedAt: Date?
    @FocusState private var composerFocused: Bool

    private let voice = VoiceAPI()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if store.visibleMessages.isEmpty && !store.isSending {
                            EmptyConversation(frozen: store.quote.isFrozen) { suggestion in
                                draft = suggestion
                                composerFocused = true
                            }
                        }

                        ForEach(store.visibleMessages) { message in
                            TurnView(
                                message: message,
                                answers: store.answersByCard[message.id] ?? [],
                                change: store.turnChanges[message.id],
                                disabled: store.quote.isFrozen || store.isSending,
                                onSubmit: { submit($0, to: message.id) }
                            )
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if store.isSending {
                            ThinkingRow(startedAt: turnStartedAt ?? Date())
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                    .animation(.easeOut(duration: 0.22), value: store.visibleMessages.count)
                }
                .onChange(of: store.visibleMessages.count) {
                    withAnimation { proxy.scrollTo(store.visibleMessages.last?.id, anchor: .bottom) }
                }
                .onChange(of: store.isSending) { _, sending in
                    turnStartedAt = sending ? Date() : nil
                    if sending { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            Divider()

            if store.quote.isFrozen {
                // Completed quotes render read-only: no composer, no interactive cards.
                Label(
                    "Completed and frozen — move it back to Draft to edit.",
                    systemImage: "lock.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                composer
            }
        }
        .alert("Voice", isPresented: .constant(voiceError != nil)) {
            Button("OK") { voiceError = nil }
        } message: {
            Text(voiceError ?? "")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if recorder.isRecording {
                RecordingBar(level: recorder.level, onCancel: recorder.cancel, onStop: finishRecording)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Camera attaches to the QUOTE, not the agent: no captioning, no analysis. The
                // photos show on the Estimate tab and in the proposal's PROJECT PHOTOS section.
                Button {
                    Task {
                        guard let jpeg = await controller.captureStill() else { return }
                        await store.attachPhotos([jpeg])
                    }
                } label: {
                    if controller.captureStatus == .idle {
                        Image(systemName: "eyeglasses").font(.title3)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 30, height: 34)
                .disabled(controller.captureStatus != .idle || store.isBusy || recorder.isRecording)
                .accessibilityLabel("Attach a photo from the glasses")

                TextField("Describe the job or add items…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .disabled(recorder.isRecording || isTranscribing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                sendOrDictate
            }

            if recorder.state == .denied {
                Text("Microphone access is off — enable it in Settings to dictate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sendOrDictate: some View {
        if isTranscribing {
            ProgressView().frame(width: 34, height: 34)
        } else if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            // Dictation is the primary input for a technician holding tools.
            Button {
                Task { await recorder.start() }
            } label: {
                Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                    .frame(width: 34, height: 34)
            }
            .disabled(store.isSending || recorder.state == .denied)
            .accessibilityLabel("Dictate")
        } else {
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .frame(width: 34, height: 34)
            }
            .disabled(store.isSending)
            .accessibilityLabel("Send")
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        Task { await store.send(content: text) }
    }

    private func finishRecording() {
        guard let recording = recorder.stop() else { return }
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                // The transcript lands in the composer rather than sending straight away, so a
                // misheard part number can be corrected before it reaches the agent.
                let text = try await voice.transcribe(audio: recording.data, mimeType: recording.mimeType)
                draft = draft.isEmpty ? text : "\(draft) \(text)"
                composerFocused = true
            } catch {
                voiceError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// One turn per card, carrying every answer — the model needs the question context, and the
    /// server ties the answers to the card that asked.
    private func submit(_ answers: [QuestionAnswer], to messageId: String) {
        guard !answers.isEmpty else { return }
        let content = answers.count == 1
            ? answers[0].value
            : answers.map { "\($0.question)\n→ \($0.value)" }.joined(separator: "\n\n")
        Task { await store.send(content: content, answers: answers, answeredMessageId: messageId) }
    }
}

// MARK: - Transcript

private struct TurnView: View {
    let message: QuoteMessage
    let answers: [QuestionAnswer]
    let change: QuoteStore.TurnChange?
    let disabled: Bool
    let onSubmit: ([QuestionAnswer]) -> Void

    var body: some View {
        if message.isUser {
            userTurn
        } else {
            agentTurn
        }
    }

    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.content.isEmpty {
                Text(message.content)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
            attachments
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var agentTurn: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark()

            VStack(alignment: .leading, spacing: 9) {
                if let thinking = message.thinkingDuration {
                    Text("Thought for \(Int(thinking.rounded()))s")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !message.content.isEmpty {
                    MarkdownText(text: message.content)
                }

                attachments

                if !message.questions.isEmpty {
                    QuestionCardGroup(
                        questions: message.questions,
                        given: answers,
                        disabled: disabled,
                        onSubmit: onSubmit
                    )
                }

                // What the turn actually did. The reply text often doesn't say.
                if let change, !change.isEmpty {
                    ChangeChip(change: change)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if let attachments = message.attachments, !attachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    RemoteThumbnail(urlString: attachment.url ?? "", width: 62, height: 48)
                }
            }
        }
    }
}

private struct AgentMark: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel("Clara")
    }
}

/// The estimate delta for one turn, stated plainly.
private struct ChangeChip: View {
    let change: QuoteStore.TurnChange

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "list.bullet.rectangle")
                .font(.caption2)
            Text(change.summary)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text("Total \(money(change.newTotal))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }
}

/// Live elapsed time, so a 40-second agent turn doesn't look like a hang.
private struct ThinkingRow: View {
    let startedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startedAt))
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Updating the estimate…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if elapsed >= 2 {
                        Text("\(elapsed)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
    }
}

/// A fresh estimate opens on something to say, not a blank page.
private struct EmptyConversation: View {
    let frozen: Bool
    let onPick: (String) -> Void

    private let suggestions = [
        "Replace 4 pendant sprinkler heads in the warehouse",
        "Quote a 60-amp EV charger install, 40 ft from the panel",
        "Annual backflow inspection and one repair",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AgentMark()
                Text("Describe the job and I'll build the estimate.")
                    .font(.subheadline)
            }

            if !frozen {
                Text("For example")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { onPick(suggestion) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "text.bubble").font(.caption)
                                Text(suggestion).font(.footnote).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 24)
    }
}

/// Shown while dictating, so it is obvious the mic is live and how to get out of it.
private struct RecordingBar: View {
    let level: Float
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.borderless)
                .font(.subheadline)

            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule()
                        .fill(Color.red.opacity(Float(index) / 18 < level ? 0.9 : 0.2))
                        .frame(width: 3, height: Float(index) / 18 < level ? 16 : 5)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.linear(duration: 0.08), value: level)

            Button("Use", action: onStop)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// All of one AI turn's questions, answered together.
///
/// The contract is explicit that this is **one turn, not one per question**: the agent is told to
/// ask everything it needs in a single round, and answering piecemeal would send it back a
/// half-answered round it then has to ask about again.
private struct QuestionCardGroup: View {
    let questions: [FollowUpQuestion]
    let given: [QuestionAnswer]
    let disabled: Bool
    let onSubmit: ([QuestionAnswer]) -> Void

    @State private var picked: [String: QuestionAnswer] = [:]
    @State private var otherFor: FollowUpQuestion?
    @State private var otherText = ""

    private var isAnswered: Bool { !given.isEmpty }
    private var allAnswered: Bool { picked.count == questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if questions.count > 1 {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .background(Color.secondary.opacity(0.15), in: Circle())
                        }
                        Text(question.question).font(.subheadline.weight(.medium))
                    }

                    if let answer = answer(for: question) {
                        Label(answer.value, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.tint)
                    } else {
                        FlowLayout(spacing: 7) {
                            ForEach(question.options) { option in
                                Button(option.label) {
                                    picked[question.id] = QuestionAnswer(
                                        questionId: question.id,
                                        question: question.question,
                                        value: option.value
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(disabled)
                            }

                            if question.showsOther {
                                Button("Other…", systemImage: "square.and.pencil") {
                                    otherText = ""
                                    otherFor = question
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(disabled)
                            }
                        }
                    }
                }
            }

            if !isAnswered {
                Button(questions.count == 1 ? "Send answer" : "Send \(picked.count) of \(questions.count) answers") {
                    onSubmit(questions.compactMap { picked[$0.id] })
                    picked = [:]
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(disabled || !allAnswered)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .alert("Your answer", isPresented: Binding(
            get: { otherFor != nil },
            set: { if !$0 { otherFor = nil } }
        )) {
            TextField("Type your answer", text: $otherText)
            Button("Cancel", role: .cancel) { otherFor = nil }
            Button("OK") {
                guard let question = otherFor else { return }
                let value = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
                otherFor = nil
                guard !value.isEmpty else { return }
                picked[question.id] = QuestionAnswer(
                    questionId: question.id,
                    question: question.question,
                    value: value,
                    fromOther: true
                )
            }
        } message: {
            Text(otherFor?.question ?? "")
        }
    }

    /// A stored answer wins over a local pick — once the server has it, the card is locked.
    private func answer(for question: FollowUpQuestion) -> QuestionAnswer? {
        given.first { $0.questionId == question.id } ?? picked[question.id]
    }
}

/// Wraps option chips onto as many rows as they need — options are short and variable, and a
/// fixed grid either clips the long ones or strands the short ones.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
