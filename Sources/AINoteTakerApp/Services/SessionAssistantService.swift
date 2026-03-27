import Foundation

@MainActor
final class SessionAssistantService {
    struct PreparedConversation {
        var userMessage: ChatMessage
        var assistantCitations: [TranscriptCitation]
        var assistantTextStream: AsyncThrowingStream<String, Error>
    }

    private let repository: SessionRepository

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func generateSummary(sessionId: UUID, settings: AppSettings) async throws -> MeetingSummary {
        guard let provider = configuredSummaryProvider(for: settings) else {
            throw AppError.providerUnavailable(reason: L10n.tr("error.summary.provider_not_configured"))
        }

        let transcript = Transcript(
            sessionId: sessionId,
            segments: try await repository.listSegments(sessionId: sessionId)
        )
        let summary = try await provider.summarize(transcript: transcript, prompt: settings.summaryPrompt)
        try await repository.saveSummary(sessionId: sessionId, summary: summary)
        return summary
    }

    func prepareConversation(
        question: String,
        sessionId: UUID,
        settings: AppSettings
    ) async throws -> PreparedConversation {
        let threadId = try await existingThreadId(for: sessionId) ?? UUID()
        let userMessage = ChatMessage(
            id: UUID(),
            threadId: threadId,
            sessionId: sessionId,
            role: .user,
            text: question,
            citations: [],
            createdAt: Date()
        )

        switch settings.cloudProvider {
        case .lmStudio:
            let provider = try configuredLMStudioChatProvider(for: settings)
            let answer = try await provider.streamAnswer(
                question: question,
                transcriptId: sessionId,
                strategy: .lexicalTopK
            )
            return PreparedConversation(
                userMessage: userMessage,
                assistantCitations: answer.citations,
                assistantTextStream: answer.textStream
            )
        case .azureOpenAI, .openAI:
            let response = try await configuredChatProvider(for: settings).answer(
                question: question,
                transcriptId: sessionId,
                strategy: .lexicalTopK
            )
            return PreparedConversation(
                userMessage: userMessage,
                assistantCitations: response.citations,
                assistantTextStream: Self.oneShotStream(response.text)
            )
        }
    }

    private func existingThreadId(for sessionId: UUID) async throws -> UUID? {
        try await repository.listChatMessages(sessionId: sessionId).first?.threadId
    }

    private func configuredSummaryProvider(for settings: AppSettings) -> (any SummarizationProvider)? {
        switch settings.cloudProvider {
        case .azureOpenAI:
            return settings.azureConfig.isChatConfigured
                ? AzureSummarizationProvider(settingsProvider: { settings })
                : nil
        case .openAI:
            return settings.openAIConfig.isConfigured
                ? OpenAISummarizationProvider(settingsProvider: { settings })
                : nil
        case .lmStudio:
            return settings.lmStudioConfig.isConfigured
                ? LMStudioSummarizationProvider(settingsProvider: { settings })
                : nil
        }
    }

    private func configuredChatProvider(for settings: AppSettings) throws -> any TranscriptChatProvider {
        switch settings.cloudProvider {
        case .azureOpenAI:
            guard settings.azureConfig.isChatConfigured else {
                throw AppError.providerUnavailable(reason: L10n.tr("error.chat.azure_not_configured"))
            }
            return AzureTranscriptChatProvider(repository: repository)
        case .openAI:
            guard settings.openAIConfig.isConfigured else {
                throw AppError.providerUnavailable(reason: L10n.tr("error.chat.openai_not_configured"))
            }
            return OpenAITranscriptChatProvider(repository: repository)
        case .lmStudio:
            return try configuredLMStudioChatProvider(for: settings)
        }
    }

    private func configuredLMStudioChatProvider(for settings: AppSettings) throws -> LMStudioTranscriptChatProvider {
        guard settings.lmStudioConfig.isConfigured else {
            throw AppError.providerUnavailable(reason: L10n.tr("error.chat.lmstudio_not_configured"))
        }
        return LMStudioTranscriptChatProvider(repository: repository)
    }

    private static func oneShotStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if !text.isEmpty {
                continuation.yield(text)
            }
            continuation.finish()
        }
    }
}
