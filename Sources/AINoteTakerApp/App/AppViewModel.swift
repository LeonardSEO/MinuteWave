import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    private enum DefaultsKeys {
        static let liveTranscriptDefaultMigrationV1 = "liveTranscriptDefaultMigrationV1"
        static let themeDefaultMigrationV1 = "themeDefaultMigrationV1"
        static let themeDefaultMigrationV2 = "themeDefaultMigrationV2"
    }
    private enum SecurityGuards {
        static let maxChatQuestionLength = 4_000
        static let maxAuditMessageLength = 180
    }

    enum StartupPreparationPhase: Equatable {
        case idle
        case restoringModelState
        case installingModel
        case ready
        case failed
    }

    struct StartupPreparationState: Equatable {
        var phase: StartupPreparationPhase
        var progress: Double
        var statusTitle: String
        var statusDetail: String
        var isActive: Bool
        var isReady: Bool

        static let idle = StartupPreparationState(
            phase: .idle,
            progress: 0.0,
            statusTitle: "",
            statusDetail: "",
            isActive: false,
            isReady: false
        )
    }

    struct PresentationError: Equatable, Identifiable {
        var id = UUID()
        var userMessage: String
        var technicalDetail: String?
    }

    @Published var settings: AppSettings = .default
    @Published var sessions: [SessionRecord] = []
    @Published var selectedSessionId: UUID?

    @Published var currentSegments: [TranscriptSegment] = []
    @Published var currentSummary: MeetingSummary?
    @Published var currentChatMessages: [ChatMessage] = []

    @Published var recordingSessionName: String = ""
    @Published var activeSessionStatus: SessionStatus = .idle
    @Published var isBusy: Bool = false
    @Published var transientError: PresentationError?
    @Published var modelInstallState: ModelInstallationState?
    @Published var isLocalRuntimeReachable: Bool = true
    @Published var localRuntimeStatusText: String = L10n.tr("ui.status.local_runtime.ready_on_demand")
    @Published var isLocalTranscriptionHealthy: Bool = false
    @Published var localTranscriptionStatusText: String = L10n.tr("ui.status.local_transcription.not_checked")
    @Published var localCaptureStatusText: String = L10n.tr("ui.status.audio.unknown")
    @Published var localCaptureWarningText: String?
    @Published var isStoppingRecording: Bool = false
    @Published var liveWaveformSamples: [Double] = Array(repeating: 0.0, count: 48)
    @Published var recordingElapsedLabel: String = "0:00"
    @Published var startupPreparation: StartupPreparationState = .idle
    @Published var lmStudioInstalled: Bool = false
    @Published var lmStudioServerReachable: Bool = false
    @Published var lmStudioLoadedModels: [LMStudioLoadedModel] = []
    @Published var lmStudioStatusText: String = L10n.tr("ui.status.lmstudio.not_checked")
    @Published var lmStudioStatusDetail: String = ""
    @Published var isLMStudioChecking: Bool = false

    private let repository: SessionRepository
    private let keychain: KeychainStore
    private let audioEngine: AudioCaptureEngine
    private let localProvider: LocalFluidAudioProvider
    private let azureProvider: AzureTranscriptionProvider
    private let openAIProvider: OpenAITranscriptionProvider
    private let recordingWorkflow: RecordingWorkflowService
    private let assistantService: SessionAssistantService

    private var exportService: ExportService { ExportService(repository: repository) }

    private var audioPumpTask: Task<Void, Never>?
    private var partialPumpTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var waveformRenderTask: Task<Void, Never>?
    private var activeProvider: (any TranscriptionProvider)?
    private var didBootstrap = false
    private var isLocalModelPreparationInProgress = false
    private var recordingStartedAt: Date?
    private var waveformTargetLevel = 0.0
    private var waveformSmoothedLevel = 0.0

    var resolvedAppLanguageCode: String {
        AppLanguageResolver.resolveLanguageCode(preference: settings.appLanguagePreference)
    }

    var resolvedLocale: Locale {
        AppLanguageResolver.locale(for: resolvedAppLanguageCode)
    }

    var isRecordingTemporarilyBlocked: Bool {
        guard settings.onboardingCompleted else { return false }
        guard settings.transcriptionConfig.providerType == .localVoxtral else { return false }
        return startupPreparation.isActive && !startupPreparation.isReady && startupPreparation.phase != .failed
    }

    var canStartRecording: Bool {
        guard !isStoppingRecording else { return false }
        guard !isRecordingTemporarilyBlocked else { return false }
        switch activeSessionStatus {
        case .idle, .completed, .failed:
            return true
        case .recording, .paused, .finalizing:
            return false
        }
    }

    var canPauseRecording: Bool {
        guard !isStoppingRecording else { return false }
        return activeSessionStatus == .recording || activeSessionStatus == .paused
    }

    var canStopRecording: Bool {
        guard !isStoppingRecording else { return false }
        return activeSessionStatus == .recording || activeSessionStatus == .paused
    }

    var canChangeAudioCaptureMode: Bool {
        Self.isAudioCaptureModeChangeAllowed(for: activeSessionStatus)
    }

    var requiresTerminationConfirmation: Bool {
        activeSessionStatus == .recording || activeSessionStatus == .paused
    }

    init(
        repository: SessionRepository,
        keychain: KeychainStore,
        audioEngine: AudioCaptureEngine,
        localProvider: LocalFluidAudioProvider,
        azureProvider: AzureTranscriptionProvider,
        openAIProvider: OpenAITranscriptionProvider
    ) {
        self.repository = repository
        self.keychain = keychain
        self.audioEngine = audioEngine
        self.localProvider = localProvider
        self.azureProvider = azureProvider
        self.openAIProvider = openAIProvider
        self.recordingWorkflow = RecordingWorkflowService(
            repository: repository,
            audioEngine: audioEngine,
            localProvider: localProvider,
            azureProvider: azureProvider,
            openAIProvider: openAIProvider
        )
        self.assistantService = SessionAssistantService(repository: repository)
        self.localProvider.onRuntimeEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleLocalRuntimeEvent(event)
            }
        }
    }

    func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true

        do {
            try DeviceGuard.validateMinimumRequirements()
            let loaded = try await repository.loadSettings()
            var normalized = normalizeSettings(loaded)
            if normalized.onboardingCompleted {
                let requirementsMet = await onboardingRequirementsSatisfied(for: normalized)
                if !requirementsMet {
                    normalized.onboardingCompleted = false
                }
            }
            settings = normalized
            syncResolvedLanguage()
            audioEngine.configure(captureMode: normalized.transcriptionConfig.audioCaptureMode)
            if normalized != loaded {
                try await repository.saveSettings(normalized)
            }
            var loadedSessions = try await repository.listSessions(search: "")
            let recoveredSessions = try await recoverInterruptedSessionsOnLaunch(in: loadedSessions)
            if recoveredSessions > 0 {
                loadedSessions = try await repository.listSessions(search: "")
            }
            sessions = loadedSessions

            if let first = sessions.first {
                await selectSession(first.id)
            }

            if let modelRef = settings.transcriptionConfig.localModelRef {
                modelInstallState = try await repository.loadModelInstallState(modelId: modelRef.modelId)
            }
            await refreshCaptureStatus()

            applyTheme(nil)

            startupPreparation = .idle
            if settings.transcriptionConfig.providerType == .localVoxtral {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready_on_demand")
            } else {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.not_used")
            }
            await refreshLMStudioRuntimeStatus()
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func applyTheme(_ appearance: NSAppearance?) {
        switch settings.theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        if appearance == nil && settings.theme == .system {
            NSApp.appearance = nil
        }
    }

    func completeOnboarding(
        with updatedSettings: AppSettings,
        azureApiKey: String?,
        openAIApiKey: String?,
        lmStudioApiKey: String?
    ) async {
        do {
            let requirements = OnboardingRequirementSnapshot(
                meetsMinimumRequirements: DeviceGuard.inspect().meetsMinimumRequirements,
                microphonePermission: Permissions.microphoneState(),
                screenCapturePermission: updatedSettings.transcriptionConfig.audioCaptureMode == .microphoneAndSystem
                    ? await Permissions.refreshScreenCaptureState()
                    : .notDetermined,
                selectedCaptureMode: updatedSettings.transcriptionConfig.audioCaptureMode
            )

            guard requirements.meetsMinimumRequirements else {
                throw AppError.unsupportedHardware(reason: L10n.tr("ui.onboarding.requirements_not_met"))
            }

            if requirements.microphonePermission != .granted {
                throw AppError.providerUnavailable(
                    reason: L10n.tr("ui.error.onboarding.microphone_required")
                )
            }

            var merged = normalizeSettings(updatedSettings)
            merged.onboardingCompleted = true
            settings = merged
            syncResolvedLanguage()
            audioEngine.configure(captureMode: merged.transcriptionConfig.audioCaptureMode)
            try await repository.saveSettings(merged)

            if let apiKey = azureApiKey, !apiKey.isEmpty {
                try keychain.set(apiKey, key: merged.azureConfig.apiKeyRef)
            }
            if let apiKey = openAIApiKey, !apiKey.isEmpty {
                try keychain.set(apiKey, key: merged.openAIConfig.apiKeyRef)
            }
            if let apiKey = lmStudioApiKey, !apiKey.isEmpty {
                try keychain.set(apiKey, key: merged.lmStudioConfig.apiKeyRef)
            }

            startupPreparation = .idle
            if merged.transcriptionConfig.providerType == .localVoxtral {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready_on_demand")
                isLocalRuntimeReachable = true
            } else {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.not_used")
                isLocalRuntimeReachable = false
            }
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.not_checked")
            isLocalTranscriptionHealthy = false
            await refreshCaptureStatus()
            await refreshLMStudioRuntimeStatus()
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func refreshSessions(search: String = "") async {
        do {
            sessions = try await repository.listSessions(search: search)
            if selectedSessionId == nil {
                selectedSessionId = sessions.first?.id
            }
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func deleteSession(_ id: UUID) async {
        let protectedStatuses: Set<SessionStatus> = [.recording, .paused, .finalizing]
        let currentStatus = sessions.first(where: { $0.id == id })?.status ?? activeSessionStatus
        guard protectedStatuses.contains(currentStatus) == false else {
            transientError = presentationError(
                userMessage: L10n.tr("startup.blocked.recording_not_ready")
            )
            return
        }

        do {
            try await repository.deleteSession(sessionId: id)
            sessions.removeAll(where: { $0.id == id })

            if selectedSessionId == id {
                if let nextSession = sessions.first {
                    await selectSession(nextSession.id)
                } else {
                    prepareNewSessionDraft()
                }
            }
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func renameSession(_ id: UUID, to rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await repository.updateSessionName(sessionId: id, name: name)
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].name = name
            }
            if selectedSessionId == id {
                recordingSessionName = name
            }
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func selectSession(_ id: UUID) async {
        if selectedSessionId != id {
            selectedSessionId = id
        }
        do {
            if let session = sessions.first(where: { $0.id == id }) {
                activeSessionStatus = session.status
            } else if let session = try await repository.getSession(id: id) {
                activeSessionStatus = session.status
            }
            if activeSessionStatus != .recording && activeSessionStatus != .paused {
                activeProvider = nil
            }
            currentSegments = try await repository.listSegments(sessionId: id)
            currentSummary = try await repository.latestSummary(sessionId: id)
            currentChatMessages = try await repository.listChatMessages(sessionId: id)
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func prepareNewSessionDraft() {
        selectedSessionId = nil
        currentSegments = []
        currentSummary = nil
        currentChatMessages = []
        activeSessionStatus = .idle
        activeProvider = nil
        isStoppingRecording = false
        recordingStartedAt = nil
        recordingElapsedLabel = "0:00"
        liveWaveformSamples = Array(repeating: 0.0, count: 48)
        recordingTimerTask?.cancel()
        waveformRenderTask?.cancel()
        waveformTargetLevel = 0
        waveformSmoothedLevel = 0
    }

    func installLocalModelIfNeeded() async {
        do {
            try await ensureLocalFluidAudioPreparedIfNeeded()
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    private func ensureLocalFluidAudioPreparedIfNeeded() async throws {
        guard settings.transcriptionConfig.providerType == .localVoxtral else { return }

        if modelInstallState?.status == .ready {
            isLocalRuntimeReachable = true
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.ready")
            return
        }

        if isLocalModelPreparationInProgress {
            while isLocalModelPreparationInProgress {
                if Task.isCancelled {
                    throw AppError.providerUnavailable(reason: L10n.tr("ui.error.local_model.preparation_cancelled"))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if modelInstallState?.status == .ready {
                return
            }
            let reason = modelInstallState?.lastError ?? L10n.tr("ui.error.local_model.preparation_failed")
            throw AppError.providerUnavailable(reason: reason)
        }

        isLocalModelPreparationInProgress = true
        defer {
            isLocalModelPreparationInProgress = false
        }

        let modelRef = settings.transcriptionConfig.localModelRef ?? .defaultParakeet
        let downloadingState = ModelInstallationState(
            modelId: modelRef.modelId,
            status: .downloading,
            progress: 0.02,
            localPath: AppPaths.fluidAudioModelsDirectory.path,
            lastError: nil
        )
        modelInstallState = downloadingState
        try? await repository.saveModelInstallState(downloadingState)
        localRuntimeStatusText = L10n.tr("ui.status.local_runtime.preparing")
        localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.preparing")

        setStartupPreparation(
            phase: .installingModel,
            progress: 0.02,
            title: L10n.tr("startup.phase.install_model.title"),
            detail: L10n.tr("startup.phase.install_model.checking_cache")
        )

        do {
            try await localProvider.prepareModelsIfNeeded(modelRef: modelRef)

            let readyState = ModelInstallationState(
                modelId: modelRef.modelId,
                status: .ready,
                progress: 1.0,
                localPath: AppPaths.fluidAudioModelsDirectory.path,
                lastError: nil
            )
            modelInstallState = readyState
            try? await repository.saveModelInstallState(readyState)
            try? await repository.addAuditEvent(category: "model", message: "FluidAudio local models ready: \(modelRef.modelId)")
            isLocalRuntimeReachable = true
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.ready")
            setStartupPreparation(
                phase: .ready,
                progress: 1.0,
                title: L10n.tr("startup.phase.ready.title"),
                detail: L10n.tr("startup.phase.ready.detail"),
                isReady: true
            )
        } catch {
            let failureMessage = error.localizedDescription
            let failedState = ModelInstallationState(
                modelId: modelRef.modelId,
                status: .failed,
                progress: 0,
                localPath: nil,
                lastError: failureMessage
            )
            modelInstallState = failedState
            try? await repository.saveModelInstallState(failedState)
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.error")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.error")
            setStartupPreparation(
                phase: .failed,
                progress: max(startupPreparation.progress, 0.3),
                title: L10n.tr("startup.phase.failed.title"),
                detail: failureMessage,
                isReady: false
            )
            throw error
        }
    }

    func startRecording(with name: String? = nil) async {
        guard canStartRecording else { return }
        if isRecordingTemporarilyBlocked {
            transientError = presentationError(userMessage: L10n.tr("startup.blocked.recording_not_ready"))
            return
        }
        let candidate = (name ?? recordingSessionName).trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = candidate.isEmpty
            ? L10n.tr("ui.main.session.default_name", Date().formatted(date: .abbreviated, time: .shortened))
            : candidate

        do {
            let startedSession = try await recordingWorkflow.startSession(
                name: sessionName,
                settings: settings,
                prepareLocalProviderIfNeeded: { [weak self] in
                    guard let self else { return }
                    try await self.ensureLocalFluidAudioPreparedIfNeeded()
                }
            )
            selectedSessionId = startedSession.session.id
            recordingSessionName = sessionName
            activeSessionStatus = .recording
            currentSegments = []
            currentSummary = nil
            currentChatMessages = []
            recordingStartedAt = Date()
            recordingElapsedLabel = "0:00"
            liveWaveformSamples = Array(repeating: 0.0, count: 48)
            waveformTargetLevel = 0
            waveformSmoothedLevel = 0
            activeProvider = startedSession.provider
            isLocalTranscriptionHealthy = false
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.connecting")
            await refreshCaptureStatus()

            recordingTimerTask?.cancel()
            recordingTimerTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await MainActor.run {
                        self.updateRecordingElapsedLabel()
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            startWaveformSmoothingLoop()

            audioPumpTask?.cancel()
            audioPumpTask = Task { [weak self] in
                guard let self else { return }
                guard let provider = self.activeProvider else { return }
                for await chunk in self.audioEngine.audioStream() {
                    let level = Self.audioLevel(fromPCM16Data: chunk.data)
                    await MainActor.run {
                        self.updateWaveformTarget(level)
                    }
                    await provider.ingestAudio(chunk)
                }
            }

            partialPumpTask?.cancel()
            partialPumpTask = Task { [weak self] in
                guard let self else { return }
                guard let provider = self.activeProvider else { return }
                for await segment in provider.partialSegmentsStream() {
                    await MainActor.run {
                        if !self.settings.transcriptionConfig.realtimeEnabled {
                            return
                        }
                        if let idx = self.currentSegments.firstIndex(where: { $0.id == segment.id }) {
                            self.currentSegments[idx] = segment
                        } else {
                            self.currentSegments.append(segment)
                        }
                    }
                }
            }

            await refreshSessions()
        } catch {
            activeProvider = nil
            await audioEngine.stop()
            await refreshCaptureStatus()
            audioPumpTask?.cancel()
            partialPumpTask?.cancel()
            recordingTimerTask?.cancel()
            recordingStartedAt = nil
            recordingElapsedLabel = "0:00"
            liveWaveformSamples = Array(repeating: 0.0, count: 48)
            waveformRenderTask?.cancel()
            waveformTargetLevel = 0
            waveformSmoothedLevel = 0
            transientError = userFacingErrorMessage(error)
            isLocalTranscriptionHealthy = false
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.error")
            activeSessionStatus = .failed
            await refreshSessions(search: "")
        }
    }

    func togglePauseRecording() async {
        guard canPauseRecording else { return }
        guard let sessionId = selectedSessionId else { return }
        if activeSessionStatus == .paused {
            activeSessionStatus = .recording
            try? await repository.updateSessionStatus(sessionId: sessionId, status: .recording, endedAt: nil)
        } else {
            activeSessionStatus = .paused
            try? await repository.updateSessionStatus(sessionId: sessionId, status: .paused, endedAt: nil)
        }
        await audioEngine.pause()
    }

    func stopRecording() async {
        guard canStopRecording else { return }
        guard let sessionId = selectedSessionId else { return }
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        activeSessionStatus = .finalizing
        defer { isStoppingRecording = false }

        do {
            let provider = activeProvider ?? recordingWorkflow.fallbackProvider(for: settings)
            await audioEngine.stop()
            await refreshCaptureStatus()
            audioPumpTask?.cancel()
            partialPumpTask?.cancel()
            recordingTimerTask?.cancel()
            recordingStartedAt = nil
            recordingElapsedLabel = "0:00"
            liveWaveformSamples = Array(repeating: 0.0, count: 48)
            waveformRenderTask?.cancel()
            waveformTargetLevel = 0
            waveformSmoothedLevel = 0

            let stoppedSession = try await recordingWorkflow.stopSession(sessionId: sessionId, provider: provider)
            currentSegments = stoppedSession.transcript.segments

            activeSessionStatus = .completed
            activeProvider = nil
            recordingStartedAt = nil
            recordingElapsedLabel = "0:00"
            liveWaveformSamples = Array(repeating: 0.0, count: 48)
            waveformRenderTask?.cancel()
            waveformTargetLevel = 0
            waveformSmoothedLevel = 0
            await refreshSessions()

            if settings.autoSummarizeAfterStop {
                await generateSummaryIfAvailable(showUnavailableError: false)
            }
        } catch {
            activeSessionStatus = .failed
            transientError = userFacingErrorMessage(error)
            isLocalTranscriptionHealthy = false
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.error")
            try? await repository.updateSessionStatus(sessionId: sessionId, status: .failed, endedAt: Date())
            try? await repository.addAuditEvent(category: "session", message: "Recording failed")
            activeProvider = nil
            recordingTimerTask?.cancel()
            recordingStartedAt = nil
            recordingElapsedLabel = "0:00"
            liveWaveformSamples = Array(repeating: 0.0, count: 48)
            waveformRenderTask?.cancel()
            waveformTargetLevel = 0
            waveformSmoothedLevel = 0
        }
    }

    func generateSummaryIfAvailable(showUnavailableError: Bool = true) async {
        guard let sessionId = selectedSessionId else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            currentSummary = try await assistantService.generateSummary(sessionId: sessionId, settings: settings)
        } catch let appError as AppError {
            if case .providerUnavailable = appError, showUnavailableError == false {
                return
            }
            transientError = userFacingErrorMessage(appError)
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func sendChat(question: String) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionId = selectedSessionId, !trimmedQuestion.isEmpty else {
            return
        }
        guard trimmedQuestion.count <= SecurityGuards.maxChatQuestionLength else {
            transientError = presentationError(
                userMessage: L10n.tr("error.chat.question_too_long", SecurityGuards.maxChatQuestionLength)
            )
            return
        }

        do {
            let preparedConversation = try await assistantService.prepareConversation(
                question: trimmedQuestion,
                sessionId: sessionId,
                settings: settings
            )
            try await repository.appendChatMessage(preparedConversation.userMessage)
            appendChatMessageToCurrentSessionIfSelected(preparedConversation.userMessage, sessionId: sessionId)
            isBusy = true
            defer { isBusy = false }

            try await consumeStreamingAssistantMessage(
                sessionId: sessionId,
                threadId: preparedConversation.userMessage.threadId,
                citations: preparedConversation.assistantCitations,
                stream: preparedConversation.assistantTextStream
            )
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func saveSettings(
        _ newSettings: AppSettings,
        azureApiKey: String?,
        openAIApiKey: String?,
        lmStudioApiKey: String?
    ) async {
        do {
            let previousEncryptionEnabled = settings.encryptionEnabled
            if newSettings.encryptionEnabled != previousEncryptionEnabled {
                if newSettings.encryptionEnabled && !SQLCipherSupport.runtimeIsAvailable() {
                    throw AppError.invalidConfiguration(
                        reason: L10n.tr("ui.error.security.sqlcipher_unavailable")
                    )
                }
                try DatabaseEncryptionStateStore().save(encryptionEnabled: newSettings.encryptionEnabled)
            }

            let normalized = normalizeSettings(newSettings)
            settings = normalized
            syncResolvedLanguage()
            audioEngine.configure(captureMode: normalized.transcriptionConfig.audioCaptureMode)
            try await repository.saveSettings(normalized)
            if let key = azureApiKey, !key.isEmpty {
                try keychain.set(key, key: normalized.azureConfig.apiKeyRef)
            }
            if let key = openAIApiKey, !key.isEmpty {
                try keychain.set(key, key: normalized.openAIConfig.apiKeyRef)
            }
            if let key = lmStudioApiKey, !key.isEmpty {
                try keychain.set(key, key: normalized.lmStudioConfig.apiKeyRef)
            }
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.not_checked")
            isLocalTranscriptionHealthy = false

            startupPreparation = .idle
            if normalized.transcriptionConfig.providerType == .localVoxtral {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready_on_demand")
                isLocalRuntimeReachable = true
            } else {
                localRuntimeStatusText = L10n.tr("ui.status.local_runtime.not_used")
                isLocalRuntimeReachable = false
            }

            if !normalized.transcriptionConfig.realtimeEnabled,
               (activeSessionStatus == .recording || activeSessionStatus == .finalizing) {
                currentSegments.removeAll(where: { !$0.isFinal })
            }
            applyTheme(nil)
            await refreshCaptureStatus()
            await refreshLMStudioRuntimeStatus()
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func updateAudioCaptureMode(_ mode: LocalAudioCaptureMode) async {
        guard canChangeAudioCaptureMode else { return }
        guard settings.transcriptionConfig.audioCaptureMode != mode else { return }
        settings.transcriptionConfig.audioCaptureMode = mode
        audioEngine.configure(captureMode: mode)
        localCaptureWarningText = nil
        switch mode {
        case .microphoneOnly:
            localCaptureStatusText = L10n.tr("ui.status.audio.microphone_only")
        case .microphoneAndSystem:
            localCaptureStatusText = L10n.tr("ui.status.audio.microphone_and_system")
        }
        do {
            try await repository.saveSettings(settings)
            await refreshCaptureStatus()
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    nonisolated static func isAudioCaptureModeChangeAllowed(for status: SessionStatus) -> Bool {
        switch status {
        case .idle, .completed, .failed:
            return true
        case .recording, .paused, .finalizing:
            return false
        }
    }

    func resetOnboardingFlow() async {
        do {
            var updated = settings
            updated.onboardingCompleted = false
            settings = updated
            startupPreparation = .idle
            try await repository.saveSettings(updated)
        } catch {
            transientError = userFacingErrorMessage(error)
        }
    }

    func refreshLMStudioRuntimeStatus() async {
        isLMStudioChecking = true
        defer { isLMStudioChecking = false }

        let snapshot = await LMStudioRuntimeClient().inspectRuntime(config: settings.lmStudioConfig)
        lmStudioInstalled = snapshot.isInstalled
        lmStudioServerReachable = snapshot.isServerReachable
        lmStudioLoadedModels = snapshot.loadedModels

        if snapshot.isInstalled == false {
            lmStudioStatusText = L10n.tr("ui.status.lmstudio.not_installed")
            lmStudioStatusDetail = ""
            return
        }

        if snapshot.isServerReachable == false {
            lmStudioStatusText = L10n.tr("ui.status.lmstudio.server_unreachable")
            lmStudioStatusDetail = snapshot.errorMessage ?? ""
            return
        }

        if snapshot.loadedModels.isEmpty {
            lmStudioStatusText = L10n.tr("ui.status.lmstudio.no_model_loaded")
            lmStudioStatusDetail = ""
        } else {
            if settings.lmStudioConfig.selectedModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || snapshot.loadedModels.contains(where: { $0.identifier == settings.lmStudioConfig.selectedModelIdentifier }) == false {
                settings.lmStudioConfig.selectedModelIdentifier = snapshot.loadedModels[0].identifier
                try? await repository.saveSettings(settings)
            }
            lmStudioStatusText = L10n.tr("ui.status.lmstudio.ready")
            lmStudioStatusDetail = snapshot.loadedModels.map(\.displayName).joined(separator: ", ")
        }
    }

    func openLMStudioApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LMStudioRuntimeClient.appBundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            return
        }
        let fallback = URL(fileURLWithPath: LMStudioRuntimeClient.appPathFallback)
        if FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.openApplication(at: fallback, configuration: .init()) { _, _ in }
        }
    }

    func openLMStudioDownloadPage() {
        guard let url = URL(string: "https://lmstudio.ai/download") else { return }
        NSWorkspace.shared.open(url)
    }

    func stopRecordingForTermination() async -> Bool {
        guard requiresTerminationConfirmation else { return true }
        transientError = nil
        await stopRecording()
        return activeSessionStatus != .failed || transientError == nil
    }

    func exportSelectedSession(as format: ExportFormat) async -> URL? {
        guard let id = selectedSessionId,
              let session = sessions.first(where: { $0.id == id }) else {
            return nil
        }

        do {
            return try await exportService.export(session: session, format: format)
        } catch {
            transientError = userFacingErrorMessage(error)
            return nil
        }
    }

    private func applyCaptureStatus(_ status: (mode: LocalAudioCaptureMode, warning: String?)) {
        localCaptureStatusText = L10n.tr("ui.status.audio.mode", status.mode.localizedLabel)
        localCaptureWarningText = status.warning
    }

    private func configuredCaptureStatus() async -> (mode: LocalAudioCaptureMode, warning: String?) {
        switch settings.transcriptionConfig.audioCaptureMode {
        case .microphoneOnly:
            return (.microphoneOnly, nil)
        case .microphoneAndSystem:
            let permission = await Permissions.refreshScreenCaptureState()
            guard permission == .granted else {
                return (.microphoneOnly, Permissions.screenCapturePermissionGuidanceMessage())
            }
            return (.microphoneAndSystem, nil)
        }
    }

    private func refreshCaptureStatus() async {
        if activeSessionStatus == .recording || activeSessionStatus == .paused || activeSessionStatus == .finalizing,
           let liveStatus = recordingWorkflow.liveCaptureStatusSummary() {
            applyCaptureStatus(liveStatus)
            return
        }

        let idleStatus = await configuredCaptureStatus()
        applyCaptureStatus(idleStatus)
    }

    private func handleLocalRuntimeEvent(_ event: LocalFluidAudioProvider.RuntimeEvent) {
        switch event {
        case .preparationStarted:
            if isLocalModelPreparationInProgress == false,
               modelInstallState?.status == .ready {
                return
            }
            isLocalRuntimeReachable = false
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.preparing")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.preparing")
        case .preparationProgress(let progress, let status, let step):
            if isLocalModelPreparationInProgress == false,
               modelInstallState?.status == .ready {
                return
            }
            isLocalRuntimeReachable = false
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.preparing")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.preparing")
            let detail = localizedPreparationDetail(for: step)
            setStartupPreparation(
                phase: .installingModel,
                progress: progress,
                title: L10n.tr("startup.phase.install_model.title"),
                detail: detail
            )

            if settings.transcriptionConfig.providerType == .localVoxtral {
                let modelRef = settings.transcriptionConfig.localModelRef ?? .defaultParakeet
                modelInstallState = ModelInstallationState(
                    modelId: modelRef.modelId,
                    status: status,
                    progress: progress,
                    localPath: AppPaths.fluidAudioModelsDirectory.path,
                    lastError: nil
                )
            }
        case .preparationReady:
            isLocalRuntimeReachable = true
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.ready")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.ready")
            if let modelId = settings.transcriptionConfig.localModelRef?.modelId {
                modelInstallState = ModelInstallationState(
                    modelId: modelId,
                    status: .ready,
                    progress: 1.0,
                    localPath: AppPaths.fluidAudioModelsDirectory.path,
                    lastError: nil
                )
            }
            setStartupPreparation(
                phase: .ready,
                progress: 1.0,
                title: L10n.tr("startup.phase.ready.title"),
                detail: L10n.tr("startup.phase.ready.detail"),
                isReady: true
            )
            scheduleStartupPreparationReset()
        case .inferenceStarted:
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.processing")
            isLocalTranscriptionHealthy = false
        case .inferenceCompleted:
            isLocalTranscriptionHealthy = true
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.healthy")
        case .warning(let message):
            isLocalTranscriptionHealthy = false
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.warning")
            Task {
                try? await repository.addAuditEvent(
                    category: "local",
                    message: sanitizedAuditMessage(message)
                )
            }
        case .preparationFailed(let message):
            isLocalRuntimeReachable = false
            isLocalTranscriptionHealthy = false
            localRuntimeStatusText = L10n.tr("ui.status.local_runtime.error")
            localTranscriptionStatusText = L10n.tr("ui.status.local_transcription.error")
            transientError = userFacingErrorMessage(AppError.providerUnavailable(reason: message))
            Task {
                try? await repository.addAuditEvent(
                    category: "local",
                    message: sanitizedAuditMessage(message)
                )
            }
        }
    }

    private func scheduleStartupPreparationReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            if self.startupPreparation.phase == .ready || self.startupPreparation.phase == .failed {
                self.startupPreparation = .idle
            }
        }
    }

    private func localizedPreparationDetail(
        for step: LocalFluidAudioProvider.PreparationStep
    ) -> String {
        switch step {
        case .checkingCache:
            return L10n.tr("startup.phase.install_model.checking_cache")
        case .downloadingAsr:
            return L10n.tr("startup.phase.install_model.downloading_asr")
        case .initializingAsr:
            return L10n.tr("startup.phase.install_model.initializing_asr")
        case .downloadingDiarizer:
            return L10n.tr("startup.phase.install_model.downloading_diarizer")
        case .initializingDiarizer:
            return L10n.tr("startup.phase.install_model.initializing_diarizer")
        }
    }

    private func updateWaveformTarget(_ value: Double) {
        waveformTargetLevel = min(max(value, 0.0), 1.0)
    }

    private func startWaveformSmoothingLoop() {
        waveformRenderTask?.cancel()
        waveformRenderTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    let next = Self.smoothedWaveformLevel(
                        current: self.waveformSmoothedLevel,
                        target: self.waveformTargetLevel
                    )
                    self.waveformSmoothedLevel = next
                    self.waveformTargetLevel = max(0, self.waveformTargetLevel * 0.92)
                    self.liveWaveformSamples.append(next)
                    if self.liveWaveformSamples.count > 48 {
                        self.liveWaveformSamples.removeFirst(self.liveWaveformSamples.count - 48)
                    }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    nonisolated static func smoothedWaveformLevel(
        current: Double,
        target: Double,
        riseAlpha: Double = 0.34,
        fallAlpha: Double = 0.16
    ) -> Double {
        let clampedCurrent = min(max(current, 0), 1)
        let clampedTarget = min(max(target, 0), 1)
        let alpha = clampedTarget >= clampedCurrent ? riseAlpha : fallAlpha
        let next = clampedCurrent + (clampedTarget - clampedCurrent) * alpha
        return min(max(next, 0), 1)
    }

    private func updateRecordingElapsedLabel() {
        guard let startedAt = recordingStartedAt else {
            recordingElapsedLabel = "0:00"
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        recordingElapsedLabel = "\(minutes):" + String(format: "%02d", seconds)
    }

    private static func audioLevel(fromPCM16Data data: Data) -> Double {
        guard data.count >= 2 else { return 0.0 }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        if sampleCount == 0 { return 0.0 }

        var sumSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let samples = base.bindMemory(to: Int16.self, capacity: sampleCount)
            for i in 0..<sampleCount {
                let normalized = Double(samples[i]) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        if rms < 0.002 {
            return 0.0
        }

        let boosted = min(1.0, rms * 14.0)
        return pow(boosted, 0.45)
    }

    private func appendChatMessageToCurrentSessionIfSelected(_ message: ChatMessage, sessionId: UUID) {
        guard selectedSessionId == sessionId else { return }
        currentChatMessages.append(message)
    }

    private func updateChatMessageInCurrentSessionIfSelected(_ message: ChatMessage, sessionId: UUID) {
        guard selectedSessionId == sessionId else { return }
        if let index = currentChatMessages.firstIndex(where: { $0.id == message.id }) {
            currentChatMessages[index] = message
        } else {
            currentChatMessages.append(message)
        }
    }

    private func removeChatMessageFromCurrentSessionIfSelected(messageId: UUID, sessionId: UUID) {
        guard selectedSessionId == sessionId else { return }
        currentChatMessages.removeAll(where: { $0.id == messageId })
    }

    private func persistAssistantMessage(
        sessionId: UUID,
        threadId: UUID,
        text: String,
        citations: [TranscriptCitation]
    ) async throws {
        let assistantMessage = ChatMessage(
            id: UUID(),
            threadId: threadId,
            sessionId: sessionId,
            role: .assistant,
            text: text,
            citations: citations,
            createdAt: Date()
        )

        try await repository.appendChatMessage(assistantMessage)
        appendChatMessageToCurrentSessionIfSelected(assistantMessage, sessionId: sessionId)
    }

    private func consumeStreamingAssistantMessage(
        sessionId: UUID,
        threadId: UUID,
        citations: [TranscriptCitation],
        stream: AsyncThrowingStream<String, Error>
    ) async throws {
        let createdAt = Date()
        var assistantMessage = ChatMessage(
            id: UUID(),
            threadId: threadId,
            sessionId: sessionId,
            role: .assistant,
            text: "",
            citations: citations,
            createdAt: createdAt
        )

        appendChatMessageToCurrentSessionIfSelected(assistantMessage, sessionId: sessionId)

        do {
            for try await chunk in stream {
                assistantMessage.text += chunk
                updateChatMessageInCurrentSessionIfSelected(assistantMessage, sessionId: sessionId)
            }

            try await repository.appendChatMessage(assistantMessage)
            updateChatMessageInCurrentSessionIfSelected(assistantMessage, sessionId: sessionId)
        } catch {
            removeChatMessageFromCurrentSessionIfSelected(messageId: assistantMessage.id, sessionId: sessionId)
            throw error
        }
    }

    private func syncResolvedLanguage() {
        L10n.setResolvedLanguageCode(resolvedAppLanguageCode)
    }

    private func userFacingErrorMessage(_ error: Error) -> PresentationError {
        let technicalDetail = technicalDetailFromError(error)
        if let appError = error as? AppError {
            switch appError {
            case .unsupportedHardware(let reason):
                return presentationError(userMessage: reason, technicalDetail: technicalDetail)
            case .providerUnavailable(let reason):
                let userMessage = normalizedProviderUnavailableUserMessage(reason)
                return presentationError(
                    userMessage: userMessage,
                    technicalDetail: userMessage == reason ? technicalDetail : sanitizedTechnicalDetail(reason)
                )
            case .invalidConfiguration:
                return presentationError(
                    userMessage: L10n.tr("error.safe.invalid_configuration"),
                    technicalDetail: technicalDetail
                )
            case .storageFailure:
                return presentationError(
                    userMessage: L10n.tr("error.safe.storage_failure"),
                    technicalDetail: technicalDetail
                )
            case .networkFailure:
                return presentationError(
                    userMessage: L10n.tr("error.safe.network_failure"),
                    technicalDetail: technicalDetail
                )
            }
        }
        return presentationError(
            userMessage: L10n.tr("error.safe.generic"),
            technicalDetail: technicalDetail
        )
    }

    private func sanitizedAuditMessage(_ message: String) -> String {
        let compact = message.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > SecurityGuards.maxAuditMessageLength else {
            return compact
        }
        return String(compact.prefix(SecurityGuards.maxAuditMessageLength)) + "..."
    }

    private func normalizedProviderUnavailableUserMessage(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return L10n.tr("ui.error.provider_unavailable_generic")
        }
        if looksLikeLocalizationKey(trimmed) || looksCrypticStatusText(trimmed) {
            return L10n.tr("ui.error.provider_unavailable_generic")
        }
        return trimmed
    }

    private func looksLikeLocalizationKey(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+$",
            options: .regularExpression
        ) != nil
    }

    private func looksCrypticStatusText(_ value: String) -> Bool {
        if value.contains("status.") || value.contains(".0.") {
            return true
        }
        if value.contains("connection.") || value.contains("network.") {
            return true
        }
        return value.contains(".") && !value.contains(" ")
    }

    private func presentationError(userMessage: String, technicalDetail: String? = nil) -> PresentationError {
        let detail = technicalDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetail = (detail?.isEmpty == false && detail != userMessage) ? detail : nil
        return PresentationError(
            userMessage: userMessage,
            technicalDetail: normalizedDetail
        )
    }

    private func technicalDetailFromError(_ error: Error) -> String? {
        if let appError = error as? AppError {
            switch appError {
            case .unsupportedHardware(let reason),
                 .invalidConfiguration(let reason),
                 .storageFailure(let reason),
                 .networkFailure(let reason),
                 .providerUnavailable(let reason):
                return sanitizedTechnicalDetail(reason)
            }
        }
        return sanitizedTechnicalDetail(error.localizedDescription)
    }

    private func sanitizedTechnicalDetail(_ detail: String) -> String {
        var sanitized = detail
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        sanitized = sanitized.replacingOccurrences(
            of: "(?i)(bearer\\s+)[A-Za-z0-9\\-\\._~\\+/=]+",
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "(?i)(api[-_ ]?key\\s*[:=]\\s*)([^\\s,;]+)",
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "(?i)(password\\s*[:=]\\s*)([^\\s,;]+)",
            with: "$1[REDACTED]",
            options: .regularExpression
        )

        if sanitized.count > 220 {
            sanitized = String(sanitized.prefix(220)) + "..."
        }
        return sanitized
    }

    private func setStartupPreparation(
        phase: StartupPreparationPhase,
        progress: Double,
        title: String,
        detail: String,
        isReady: Bool = false
    ) {
        startupPreparation = StartupPreparationState(
            phase: phase,
            progress: min(max(progress, 0.0), 1.0),
            statusTitle: title,
            statusDetail: detail,
            isActive: true,
            isReady: isReady
        )
    }

    private func recoverInterruptedSessionsOnLaunch(in sessions: [SessionRecord]) async throws -> Int {
        let interrupted = sessions.filter { session in
            session.status == .recording || session.status == .paused || session.status == .finalizing
        }
        guard !interrupted.isEmpty else { return 0 }

        let endedAt = Date()
        for session in interrupted {
            try await repository.updateSessionStatus(sessionId: session.id, status: .failed, endedAt: endedAt)
        }
        try? await repository.addAuditEvent(
            category: "session",
            message: "Recovered \(interrupted.count) interrupted session(s) on launch"
        )
        return interrupted.count
    }

    private func onboardingRequirementsSatisfied(for settings: AppSettings) async -> Bool {
        let snapshot = OnboardingRequirementSnapshot(
            meetsMinimumRequirements: DeviceGuard.inspect().meetsMinimumRequirements,
            microphonePermission: Permissions.microphoneState(),
            screenCapturePermission: settings.transcriptionConfig.audioCaptureMode == .microphoneAndSystem
                ? await Permissions.refreshScreenCaptureState()
                : .notDetermined,
            selectedCaptureMode: settings.transcriptionConfig.audioCaptureMode
        )
        return OnboardingRequirementsEvaluator.permissionsStepIsSatisfied(snapshot)
    }

    private func normalizeSettings(_ incoming: AppSettings) -> AppSettings {
        var normalized = incoming
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: DefaultsKeys.themeDefaultMigrationV1) == false {
            defaults.set(true, forKey: DefaultsKeys.themeDefaultMigrationV1)
        }
        if defaults.bool(forKey: DefaultsKeys.themeDefaultMigrationV2) == false {
            if normalized.theme == .dark {
                normalized.theme = .system
            }
            defaults.set(true, forKey: DefaultsKeys.themeDefaultMigrationV2)
        }

        normalized.azureConfig.transcriptionDeployment = AzureModelPolicy.transcriptionDeployment
        normalized.azureConfig.summaryDeployment = AzureModelPolicy.summaryDeployment
        normalized.azureConfig.chatDeployment = AzureModelPolicy.chatDeployment
        if normalized.azureConfig.chatAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.azureConfig.chatAPIVersion = AzureModelPolicy.defaultChatAPIVersion
        }
        if normalized.azureConfig.transcriptionAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.azureConfig.transcriptionAPIVersion = AzureModelPolicy.defaultTranscriptionAPIVersion
        }

        if normalized.openAIConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.openAIConfig.baseURL = OpenAIModelPolicy.defaultBaseURL
        }
        if normalized.openAIConfig.chatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.openAIConfig.chatModel = OpenAIModelPolicy.chatModel
        }
        if normalized.openAIConfig.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.openAIConfig.summaryModel = OpenAIModelPolicy.summaryModel
        }
        if normalized.openAIConfig.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.openAIConfig.transcriptionModel = OpenAIModelPolicy.transcriptionModel
        }
        if normalized.lmStudioConfig.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.lmStudioConfig.endpoint = LMStudioConfig.default.endpoint
        }
        if normalized.lmStudioConfig.apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.lmStudioConfig.apiKeyRef = LMStudioConfig.default.apiKeyRef
        }

        normalized.transcriptionConfig.azureConfig = normalized.azureConfig
        normalized.transcriptionConfig.openAIConfig = normalized.openAIConfig
        if normalized.transcriptionConfig.providerType == .openAI,
           normalized.cloudProvider != .lmStudio {
            normalized.cloudProvider = .openAI
        } else if normalized.transcriptionConfig.providerType == .azure,
                    normalized.cloudProvider != .lmStudio {
            normalized.cloudProvider = .azureOpenAI
        }

        normalized.summaryPrompt = normalized.summaryPrompt.normalizedAgainstKnownDefaults()

        let persistedEncryptionFlag = DatabaseEncryptionStateStore().load(defaultValue: normalized.encryptionEnabled)
        normalized.encryptionEnabled = persistedEncryptionFlag
        if normalized.encryptionEnabled && !SQLCipherSupport.runtimeIsAvailable() {
            AppLogger.security.warning(
                "SQLCipher runtime unavailable during settings normalization; forcing encryptionEnabled=false."
            )
            normalized.encryptionEnabled = false
            try? DatabaseEncryptionStateStore().save(encryptionEnabled: false)
        }

        if normalized.transcriptionConfig.providerType == .localVoxtral {
            normalized.transcriptionConfig.realtimeEnabled = false
            if defaults.bool(forKey: DefaultsKeys.liveTranscriptDefaultMigrationV1) == false {
                defaults.set(true, forKey: DefaultsKeys.liveTranscriptDefaultMigrationV1)
            }

            if let existing = normalized.transcriptionConfig.localModelRef,
               existing.modelId == "mistralai/Voxtral-Mini-4B-Realtime-2602"
                || existing.modelId == "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit" {
                normalized.transcriptionConfig.localModelRef = .defaultParakeet
            }
            if normalized.transcriptionConfig.localModelRef == nil {
                normalized.transcriptionConfig.localModelRef = .defaultParakeet
            }
        }
        return normalized
    }

}
