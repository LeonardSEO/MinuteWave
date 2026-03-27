import Foundation

@MainActor
final class RecordingWorkflowService {
    struct StartedSession {
        var session: SessionRecord
        var provider: any TranscriptionProvider
    }

    struct StoppedSession {
        var transcript: Transcript
    }

    private let repository: SessionRepository
    private let audioEngine: AudioCaptureEngine
    private let localProvider: LocalFluidAudioProvider
    private let azureProvider: AzureTranscriptionProvider
    private let openAIProvider: OpenAITranscriptionProvider

    init(
        repository: SessionRepository,
        audioEngine: AudioCaptureEngine,
        localProvider: LocalFluidAudioProvider,
        azureProvider: AzureTranscriptionProvider,
        openAIProvider: OpenAITranscriptionProvider
    ) {
        self.repository = repository
        self.audioEngine = audioEngine
        self.localProvider = localProvider
        self.azureProvider = azureProvider
        self.openAIProvider = openAIProvider
    }

    func startSession(
        name: String,
        settings: AppSettings,
        prepareLocalProviderIfNeeded: () async throws -> Void
    ) async throws -> StartedSession {
        var createdSession: SessionRecord?

        do {
            if settings.transcriptionConfig.providerType == .localVoxtral {
                try await prepareLocalProviderIfNeeded()
            }

            let session = try await repository.createSession(
                name: name,
                provider: settings.transcriptionConfig.providerType
            )
            createdSession = session

            try await repository.updateSessionStatus(sessionId: session.id, status: .recording, endedAt: nil)

            let provider = try transcriptionProvider(for: settings)
            try await provider.startSession(config: settings.transcriptionConfig, sessionId: session.id)

            audioEngine.configure(captureMode: settings.transcriptionConfig.audioCaptureMode)
            try await audioEngine.start()

            try await repository.addAuditEvent(category: "session", message: "Recording started")
            return StartedSession(session: session, provider: provider)
        } catch {
            if let createdSession {
                try? await repository.updateSessionStatus(
                    sessionId: createdSession.id,
                    status: .failed,
                    endedAt: Date()
                )
            }
            throw error
        }
    }

    func stopSession(sessionId: UUID, provider: any TranscriptionProvider) async throws -> StoppedSession {
        let transcript = try await provider.stopSession()

        for segment in transcript.segments {
            try await repository.insertSegment(segment)
        }

        try await repository.upsertTranscriptChunks(
            sessionId: sessionId,
            chunks: chunkTranscriptForRetrieval(transcript)
        )
        try await repository.updateSessionStatus(sessionId: sessionId, status: .completed, endedAt: Date())
        try await repository.addAuditEvent(category: "session", message: "Recording completed")

        return StoppedSession(transcript: transcript)
    }

    func fallbackProvider(for settings: AppSettings) -> any TranscriptionProvider {
        switch settings.transcriptionConfig.providerType {
        case .localVoxtral:
            return localProvider
        case .azure:
            return azureProvider
        case .openAI:
            return openAIProvider
        }
    }

    func liveCaptureStatusSummary() -> (mode: LocalAudioCaptureMode, warning: String?)? {
        (audioEngine as? HybridAudioCaptureEngine)?.captureStatusSummary()
    }

    private func transcriptionProvider(for settings: AppSettings) throws -> any TranscriptionProvider {
        switch settings.transcriptionConfig.providerType {
        case .localVoxtral:
            return localProvider
        case .azure:
            guard settings.azureConfig.isTranscriptionConfigured else {
                throw AppError.providerUnavailable(reason: L10n.tr("error.transcription.azure_not_configured"))
            }
            return azureProvider
        case .openAI:
            guard settings.openAIConfig.isConfigured else {
                throw AppError.providerUnavailable(reason: L10n.tr("error.transcription.openai_not_configured"))
            }
            return openAIProvider
        }
    }

    private func chunkTranscriptForRetrieval(_ transcript: Transcript, maxChars: Int = 480) -> [String] {
        var chunks: [String] = []
        var current = ""

        for segment in transcript.segments {
            let speakerPrefix = segment.speakerLabel.map { "\($0): " } ?? ""
            let piece = "[\(segment.startMs)-\(segment.endMs)] \(speakerPrefix)\(segment.text)\n"
            if current.count + piece.count > maxChars && !current.isEmpty {
                chunks.append(current)
                current = piece
            } else {
                current += piece
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }
}
