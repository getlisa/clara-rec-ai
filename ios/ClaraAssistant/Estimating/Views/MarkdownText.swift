import SwiftUI

/// Renders the agent's markdown with its block structure intact.
///
/// `AttributedString(markdown:)` alone collapses everything to one run of inline text, which is
/// wrong for this agent specifically: it is instructed to "reply with a clearly itemized list of
/// the equipment/materials needed", so bullets are most of what it says. Flattened, a ten-item
/// parts list arrives as one unreadable paragraph.
///
/// Inline formatting (bold, italic, code, links) still goes through AttributedString — only the
/// block level is parsed here.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    inline(content)
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 2)

                case .paragraph(let content):
                    inline(content)

                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                inline(item)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func inline(_ source: String) -> Text {
        Text(
            (try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(source)
        )
    }

    // MARK: - Parsing

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(items: [String], ordered: Bool)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: listIsOrdered))
            listItems = []
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                flushList()
                continue
            }

            if let bullet = Self.bulletContent(line) {
                flushParagraph()
                if !listItems.isEmpty && listIsOrdered { flushList() }
                listIsOrdered = false
                listItems.append(bullet)
                continue
            }

            if let numbered = Self.numberedContent(line) {
                flushParagraph()
                if !listItems.isEmpty && !listIsOrdered { flushList() }
                listIsOrdered = true
                listItems.append(numbered)
                continue
            }

            if line.hasPrefix("#") {
                flushParagraph()
                flushList()
                let level = line.prefix(while: { $0 == "#" }).count
                let content = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { blocks.append(.heading(level: level, text: content)) }
                continue
            }

            flushList()
            paragraph.append(line)
        }

        flushParagraph()
        flushList()
        return blocks
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `1. text` / `2) text` — the digits are re-numbered on render, so their value is ignored.
    private static func numberedContent(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
}
