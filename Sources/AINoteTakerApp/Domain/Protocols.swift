import Foundation

protocol TranscriptionProvider: Sendable {
    var providerType: TranscriptionProviderType { get }
    func startSession(config: TranscriptionConfig, sessionId: UUID) async throws
    func ingestAudio(_ buffer: AudioChunk) async
    func stopSession() async throws -> Transcript
    func partialSegmentsStream() -> AsyncStream<TranscriptSegment>
}

protocol SummarizationProvider: Sendable {
    func summarize(transcript: Transcript, prompt: SummaryPrompt) async throws -> MeetingSummary
}

protocol TranscriptChatProvider: Sendable {
    func answer(question: String, transcriptId: UUID, strategy: RetrievalStrategy) async throws -> ChatAnswer
}

protocol AudioCaptureEngine: Sendable {
    func configure(captureMode: LocalAudioCaptureMode)
    func start() async throws
    func pause() async
    func stop() async
    func audioStream() -> AsyncStream<AudioChunk>
}

protocol SessionRepository: Sendable {
    func createSession(name: String, provider: TranscriptionProviderType) async throws -> SessionRecord
    func updateSessionStatus(sessionId: UUID, status: SessionStatus, endedAt: Date?) async throws
    func updateSessionName(sessionId: UUID, name: String) async throws
    func listSessions(search: String) async throws -> [SessionRecord]
    func getSession(id: UUID) async throws -> SessionRecord?

    func insertSegment(_ segment: TranscriptSegment) async throws
    func listSegments(sessionId: UUID) async throws -> [TranscriptSegment]
    func upsertTranscriptChunks(sessionId: UUID, chunks: [String]) async throws

    func saveSummary(sessionId: UUID, summary: MeetingSummary) async throws
    func latestSummary(sessionId: UUID) async throws -> MeetingSummary?

    func appendChatMessage(_ message: ChatMessage) async throws
    func listChatMessages(sessionId: UUID) async throws -> [ChatMessage]

    func saveSettings(_ settings: AppSettings) async throws
    func loadSettings() async throws -> AppSettings

    func saveModelInstallState(_ state: ModelInstallationState) async throws
    func loadModelInstallState(modelId: String) async throws -> ModelInstallationState?

    func addAuditEvent(category: String, message: String) async throws
}
