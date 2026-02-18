import SwiftUI

struct MarkdownSummaryView: View {
    private let source: String
    private let attributed: AttributedString?

    init(source: String) {
        self.source = source
        self.attributed = MarkdownSummaryView.parseMarkdown(source)
    }

    var body: some View {
        if let attributed {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(source)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func parseMarkdown(_ source: String) -> AttributedString? {
        // Guard against malformed control bytes that can break visual rendering in text views.
        let hasUnsupportedControl = source.unicodeScalars.contains(where: { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return false
            default:
                return CharacterSet.controlCharacters.contains(scalar)
            }
        })
        guard !hasUnsupportedControl else { return nil }

        return try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .throwError
            )
        )
    }
}
