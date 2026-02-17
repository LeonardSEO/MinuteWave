import Foundation

struct LocalFallbackSummarizationProvider: SummarizationProvider {
    func summarize(transcript: Transcript, prompt: SummaryPrompt) async throws -> MeetingSummary {
        _ = prompt
        let lines = transcript.plainText.split(separator: "\n").map(String.init)
        let summary = lines.prefix(8).joined(separator: "\n")

        return MeetingSummary(
            title: "Lokale samenvatting",
            executiveSummary: summary.isEmpty ? "Geen transcript beschikbaar." : summary,
            decisions: [],
            actionItems: [],
            openQuestions: [],
            followUps: [],
            risks: [],
            generatedAt: Date(),
            version: 1
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
