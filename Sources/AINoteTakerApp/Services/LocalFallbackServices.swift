import Foundation

struct LocalFallbackSummarizationProvider: SummarizationProvider {
    func summarize(transcript: Transcript, prompt: SummaryPrompt) async throws -> MeetingSummary {
        _ = prompt
        let lines = transcript.plainText.split(separator: "\n").map(String.init)
        let bullets = lines
            .prefix(6)
            .map { "- \($0)" }
            .joined(separator: "\n")
        let context = lines.first ?? "Unknown"
        let summaryMarkdown = """
## 1. Context
\(context)

## 2. Executive Summary
\(bullets.isEmpty ? "- Unknown" : bullets)

## 3. Decisions
- Unknown

## 4. Action Items
- Unknown | Unknown | Unknown

## 5. Open Questions and Risks
- Unknown

## 6. Key Details
- Unknown

## 7. Next Steps (Next 7 Days)
- Unknown
"""

        return MeetingSummaryBuilder.build(
            from: summaryMarkdown,
            fallbackTitle: "Local summary",
            generatedAt: Date()
        )
    }
}

struct UnavailableChatProvider: TranscriptChatProvider {
    func answer(question: String, transcriptId: UUID, strategy: RetrievalStrategy) async throws -> ChatAnswer {
        _ = question
        _ = transcriptId
        _ = strategy
        throw AppError.providerUnavailable(reason: "Chat provider is not configured. Configure Azure/OpenAI in Settings.")
    }
}
