import Foundation

enum MeetingSummaryBuilder {
    struct Sections: Equatable {
        var context: [String] = []
        var executiveSummary: [String] = []
        var decisions: [String] = []
        var actionItems: [String] = []
        var openQuestions: [String] = []
        var followUps: [String] = []
        var risks: [String] = []
    }

    private enum SectionKey {
        case context
        case executiveSummary
        case decisions
        case actionItems
        case openQuestions
        case risks
        case openQuestionsAndRisks
        case nextSteps
        case keyDetails
    }

    static func build(from markdown: String, fallbackTitle: String, generatedAt: Date = Date()) -> MeetingSummary {
        let sections = parseSections(from: markdown)
        return MeetingSummary(
            title: title(from: sections.context, fallback: fallbackTitle),
            executiveSummary: normalizedMarkdown(markdown),
            decisions: sections.decisions,
            actionItems: sections.actionItems,
            openQuestions: sections.openQuestions,
            followUps: sections.followUps,
            risks: sections.risks,
            generatedAt: generatedAt,
            version: 1
        )
    }

    static func parseSections(from markdown: String) -> Sections {
        let normalized = normalizedMarkdown(markdown)
        let lines = normalized.components(separatedBy: .newlines)

        var groupedLines: [SectionKey: [String]] = [:]
        var currentSection: SectionKey?

        for line in lines {
            if let section = sectionKey(forHeadingLine: line) {
                currentSection = section
                groupedLines[section, default: []] = groupedLines[section, default: []]
                continue
            }

            guard let currentSection else { continue }
            groupedLines[currentSection, default: []].append(line)
        }

        let context = extractItems(from: groupedLines[.context] ?? [])
        let executiveSummary = extractItems(from: groupedLines[.executiveSummary] ?? [])
        let decisions = extractItems(from: groupedLines[.decisions] ?? [])
        let actionItems = extractItems(from: groupedLines[.actionItems] ?? [])
        let directOpenQuestions = extractItems(from: groupedLines[.openQuestions] ?? [])
        let directRisks = extractItems(from: groupedLines[.risks] ?? [])
        let combined = extractItems(from: groupedLines[.openQuestionsAndRisks] ?? [])
        let followUps = extractItems(from: groupedLines[.nextSteps] ?? [])

        let split = splitOpenQuestionsAndRisks(combined)

        return Sections(
            context: context,
            executiveSummary: executiveSummary,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: directOpenQuestions + split.openQuestions,
            followUps: followUps,
            risks: directRisks + split.risks
        )
    }

    private static func normalizedMarkdown(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func title(from context: [String], fallback: String) -> String {
        guard let first = context.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            return fallback
        }

        let sentence = first.split(separator: ".").first.map(String.init) ?? first
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.count <= 96 {
            return trimmed
        }
        return String(trimmed.prefix(93)) + "..."
    }

    private static func extractItems(from lines: [String]) -> [String] {
        var items: [String] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let bullet = stripBulletPrefix(from: trimmed) {
                items.append(bullet)
                continue
            }

            if items.isEmpty {
                items.append(trimmed)
            } else {
                items[items.count - 1] += " " + trimmed
            }
        }

        return items
    }

    private static func splitOpenQuestionsAndRisks(_ items: [String]) -> (openQuestions: [String], risks: [String]) {
        guard !items.isEmpty else {
            return ([], [])
        }

        var openQuestions: [String] = []
        var risks: [String] = []

        for item in items {
            let normalized = item
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = normalized.lowercased()

            if isUnknownPlaceholder(lowercased) {
                if openQuestions.isEmpty {
                    openQuestions.append(item)
                }
                if risks.isEmpty {
                    risks.append(item)
                }
                continue
            }

            if looksLikeRisk(lowercased) {
                risks.append(item)
            } else {
                openQuestions.append(item)
            }
        }

        return (openQuestions, risks)
    }

    private static func isUnknownPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized == "unknown"
            || normalized == "onbekend"
            || normalized == "none"
            || normalized == "geen"
    }

    private static func looksLikeRisk(_ value: String) -> Bool {
        value.contains("risk")
            || value.contains("risks")
            || value.contains("risico")
            || value.contains("blocker")
            || value.contains("blocked")
            || value.contains("dependency")
    }

    private static func stripBulletPrefix(from line: String) -> String? {
        let patterns = [
            #"^[-*•]\s+"#,
            #"^\d+[.)]\s+"#
        ]

        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private static func sectionKey(forHeadingLine line: String) -> SectionKey? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let looksLikeMarkdownHeading = trimmed.hasPrefix("#")
        let looksLikeNumberedHeading = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
        guard looksLikeMarkdownHeading || looksLikeNumberedHeading else {
            return nil
        }

        let heading = trimmed
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if heading.contains("context") || heading.contains("achtergrond") || heading == "doel" {
            return .context
        }
        if heading.contains("executive summary") || heading.contains("summary") || heading.contains("samenvatting") {
            return .executiveSummary
        }
        if heading.contains("decision") || heading.contains("besluit") {
            return .decisions
        }
        if heading.contains("action item") || heading.contains("actiepunt") || heading.contains("actiepunten") {
            return .actionItems
        }
        if heading.contains("open questions and risks")
            || heading.contains("vragen en risico")
            || (heading.contains("question") && heading.contains("risk"))
            || (heading.contains("vraag") && heading.contains("risico")) {
            return .openQuestionsAndRisks
        }
        if heading.contains("open question") || heading.contains("vragen") || heading.contains("question") || heading.contains("vraag") {
            return .openQuestions
        }
        if heading.contains("follow-up") || heading.contains("follow up") || heading.contains("next step") || heading.contains("volgende stap") {
            return .nextSteps
        }
        if heading.contains("risk") || heading.contains("risico") {
            return .risks
        }
        if heading.contains("key detail") || heading.contains("details") || heading.contains("belangrijke details") {
            return .keyDetails
        }

        return nil
    }
}
