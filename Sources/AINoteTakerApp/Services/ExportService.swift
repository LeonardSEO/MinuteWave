import Foundation

struct ExportService {
    private let repository: SessionRepository
    private let fileManager = FileManager.default

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func export(session: SessionRecord, format: ExportFormat) async throws -> URL {
        let segments = try await repository.listSegments(sessionId: session.id)
        let summary = try await repository.latestSummary(sessionId: session.id)

        try fileManager.createDirectory(at: AppPaths.exportsDirectory, withIntermediateDirectories: true)

        let filenameRoot = sanitize(session.name) + "-" + ISO8601DateFormatter().string(from: session.startedAt)
        let url = AppPaths.exportsDirectory.appendingPathComponent(filenameRoot).appendingPathExtension(format.fileExtension)

        let content: Data
        switch format {
        case .markdown:
            content = Data(markdown(session: session, segments: segments, summary: summary).utf8)
        case .txt:
            content = Data(txt(session: session, segments: segments, summary: summary).utf8)
        case .json:
            content = try json(session: session, segments: segments, summary: summary)
        }

        try content.write(to: url)
        return url
    }

    private func markdown(session: SessionRecord, segments: [TranscriptSegment], summary: MeetingSummary?) -> String {
        var output = "# \(session.name)\n\n"
        output += "- \(L10n.tr("export.start")): \(session.startedAt.formatted())\n"
        if let ended = session.endedAt {
            output += "- \(L10n.tr("export.end")): \(ended.formatted())\n"
        }
        output += "\n## \(L10n.tr("export.summary"))\n\n"
        output += summary?.executiveSummary ?? L10n.tr("export.no_summary")
        output += "\n\n## \(L10n.tr("export.transcript"))\n\n"

        for segment in segments {
            let speakerPrefix = segment.speakerLabel.map { "\($0): " } ?? ""
            output += "- [\(segment.startMs)-\(segment.endMs)] \(speakerPrefix)\(segment.text)\n"
        }

        return output
    }

    private func txt(session: SessionRecord, segments: [TranscriptSegment], summary: MeetingSummary?) -> String {
        var output = "\(session.name)\n"
        output += "\(L10n.tr("export.start")): \(session.startedAt.formatted())\n"
        output += "\n\(L10n.tr("export.summary")):\n\(summary?.executiveSummary ?? L10n.tr("export.no_summary"))\n\n\(L10n.tr("export.transcript")):\n"

        for segment in segments {
            let speakerPrefix = segment.speakerLabel.map { "\($0): " } ?? ""
            output += "[\(segment.startMs)-\(segment.endMs)] \(speakerPrefix)\(segment.text)\n"
        }

        return output
    }

    private func json(session: SessionRecord, segments: [TranscriptSegment], summary: MeetingSummary?) throws -> Data {
        struct Payload: Codable {
            var session: SessionRecord
            var summary: MeetingSummary?
            var segments: [TranscriptSegment]
        }

        return try JSONEncoder.pretty.encode(Payload(session: session, summary: summary, segments: segments))
    }

    private func sanitize(_ input: String) -> String {
        input.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case txt
    case json

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .txt: return "txt"
        case .json: return "json"
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
