import SwiftUI

/// A markdown text view that renders as a single selectable `Text`, allowing
/// text selection across paragraph breaks. Replaces MarkdownUI's `Markdown`
/// which creates separate views per block and breaks cross-paragraph selection.
struct SelectableMarkdown: View {
    let text: String
    let sender: ChatSender
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let fontSize = round(14 * fontScale)
        let processed = Self.preprocess(text)

        if let styled = Self.styledAttributedString(
            from: processed, sender: sender, fontSize: fontSize, fontScale: fontScale
        ) {
            Text(styled)
                .if_available_writingToolsNone()
        } else {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(sender == .user ? .white : OmiColors.textPrimary)
                .if_available_writingToolsNone()
        }
    }

    private static func styledAttributedString(
        from processed: String, sender: ChatSender, fontSize: CGFloat, fontScale: CGFloat
    ) -> AttributedString? {
        guard var attributed = try? AttributedString(
            markdown: processed,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else { return nil }

        let codeFontSize = round(13 * fontScale)
        let baseColor: Color = sender == .user ? .white : OmiColors.textPrimary
        let linkColor: Color = sender == .user ? .white.opacity(0.9) : OmiColors.purplePrimary
        let codeBgColor: Color = sender == .user
            ? .white.opacity(0.15)
            : OmiColors.backgroundTertiary

        attributed.font = .system(size: fontSize)
        attributed.foregroundColor = baseColor

        var codeRanges = [Range<AttributedString.Index>]()
        var linkRanges = [Range<AttributedString.Index>]()

        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            }
            if run.link != nil {
                linkRanges.append(run.range)
            }
        }

        for range in codeRanges {
            attributed[range].font = .system(size: codeFontSize, design: .monospaced)
            attributed[range].backgroundColor = codeBgColor
        }

        for range in linkRanges {
            attributed[range].foregroundColor = linkColor
            if sender == .user {
                attributed[range].underlineStyle = .single
            }
        }

        return attributed
    }

    /// Pre-processes markdown to convert block-level elements into inline-compatible
    /// form, since we use `.inlineOnlyPreservingWhitespace` for a single `Text` view.
    static func preprocess(_ text: String) -> String {
        var result = [String]()
        var inCodeBlock = false
        var codeBlockLines = [String]()

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect code block fences
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block — join lines, each wrapped as inline code
                    let code = codeBlockLines.joined(separator: "\n")
                    // Wrap entire code block content in backticks
                    // Escape any existing backticks
                    let escaped = code.replacingOccurrences(of: "`", with: "'")
                    result.append("`\(escaped)`")
                    codeBlockLines = []
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            var processed = line

            // Convert headers to bold text
            if let match = processed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let headerText = String(processed[match.upperBound...])
                processed = "**\(headerText)**"
            }

            // Convert "* item" list markers to "• item" so asterisks
            // aren't parsed as italic markers by inline markdown
            processed = processed.replacingOccurrences(
                of: #"^(\s*)\* "#,
                with: "$1• ",
                options: .regularExpression
            )

            result.append(processed)
        }

        // Handle unclosed code block
        if inCodeBlock && !codeBlockLines.isEmpty {
            let code = codeBlockLines.joined(separator: "\n")
            let escaped = code.replacingOccurrences(of: "`", with: "'")
            result.append("`\(escaped)`")
        }

        return result.joined(separator: "\n")
    }
}
