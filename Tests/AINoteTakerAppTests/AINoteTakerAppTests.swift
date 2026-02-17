import Foundation
import Testing
@testable import AINoteTakerApp

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let migrationTestKeyHex = String(repeating: "ab", count: 48)

private func cleanupDatabaseFiles(at databaseURL: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: databaseURL)
    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
}

private func seedMigrationFixture(
    repository: SQLiteRepository,
    sessionName: String
) async throws -> UUID {
    let session = try await repository.createSession(name: sessionName, provider: .localVoxtral)
    try await repository.updateSessionStatus(sessionId: session.id, status: .completed, endedAt: Date())

    let segment = TranscriptSegment(
        id: UUID(),
        sessionId: session.id,
        startMs: 0,
        endMs: 1200,
        text: "Migratie testsegment",
        confidence: 0.99,
        sourceProvider: .localVoxtral,
        isFinal: true
    )
    try await repository.insertSegment(segment)

    let summary = MeetingSummary(
        title: "Migratie samenvatting",
        executiveSummary: "Belangrijke punten blijven behouden na migratie.",
        decisions: ["Doorgaan met release"],
        actionItems: ["Valideer migratie"],
        openQuestions: [],
        followUps: [],
        risks: [],
        generatedAt: Date(),
        version: 1
    )
    try await repository.saveSummary(sessionId: session.id, summary: summary)

    let message = ChatMessage(
        id: UUID(),
        threadId: UUID(),
        sessionId: session.id,
        role: .assistant,
        text: "Migratie-chatbericht",
        citations: [TranscriptCitation(segmentId: segment.id, startMs: 0, endMs: 1200)],
        createdAt: Date()
    )
    try await repository.appendChatMessage(message)
    return session.id
}

private func assertMigrationFixture(
    repository: SQLiteRepository,
    sessionId: UUID,
    expectedSessionName: String
) async throws {
    let session = try await repository.getSession(id: sessionId)
    #expect(session?.name == expectedSessionName)
    #expect(session?.status == .completed)

    let segments = try await repository.listSegments(sessionId: sessionId)
    #expect(segments.count == 1)
    #expect(segments[0].text == "Migratie testsegment")

    let summary = try await repository.latestSummary(sessionId: sessionId)
    #expect(summary?.executiveSummary == "Belangrijke punten blijven behouden na migratie.")

    let messages = try await repository.listChatMessages(sessionId: sessionId)
    #expect(messages.count == 1)
    #expect(messages[0].text == "Migratie-chatbericht")
}

@Test("Default settings roundtrip")
func defaultSettingsRoundTrip() async throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")

    let repository = try SQLiteRepository(databaseURL: tempDB)
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let settings = AppSettings.default
    try await repository.saveSettings(settings)
    let loaded = try await repository.loadSettings()

    #expect(loaded.theme == settings.theme)
    #expect(loaded.autoSummarizeAfterStop == settings.autoSummarizeAfterStop)
    #expect(loaded.transcriptionConfig.providerType == settings.transcriptionConfig.providerType)
}

@Test("Session lifecycle")
func sessionLifecycle() async throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")

    let repository = try SQLiteRepository(databaseURL: tempDB)
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let session = try await repository.createSession(name: "Demo", provider: .localVoxtral)
    try await repository.updateSessionStatus(sessionId: session.id, status: .completed, endedAt: Date())

    let sessions = try await repository.listSessions(search: "Dem")
    #expect(sessions.count == 1)
    #expect(sessions[0].name == "Demo")
}

@Test("Transcript segment speaker label roundtrip")
func transcriptSpeakerLabelRoundTrip() async throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")

    let repository = try SQLiteRepository(databaseURL: tempDB)
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let session = try await repository.createSession(name: "Speaker labels", provider: .localVoxtral)
    let segment = TranscriptSegment(
        id: UUID(),
        sessionId: session.id,
        startMs: 100,
        endMs: 1800,
        text: "Hallo allemaal",
        confidence: 0.97,
        sourceProvider: .localVoxtral,
        isFinal: true,
        speakerLabel: "S1"
    )
    try await repository.insertSegment(segment)

    let loaded = try await repository.listSegments(sessionId: session.id)
    #expect(loaded.count == 1)
    #expect(loaded[0].speakerLabel == "S1")
}

@Test("Chat and citations roundtrip")
func chatRoundTrip() async throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")

    let repository = try SQLiteRepository(databaseURL: tempDB)
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let session = try await repository.createSession(name: "Chat session", provider: .localVoxtral)
    let threadId = UUID()
    let citation = TranscriptCitation(segmentId: UUID(), startMs: 1200, endMs: 2400)
    let message = ChatMessage(
        id: UUID(),
        threadId: threadId,
        sessionId: session.id,
        role: .assistant,
        text: "Actiepunt toegewezen.",
        citations: [citation],
        createdAt: Date()
    )

    try await repository.appendChatMessage(message)
    let loaded = try await repository.listChatMessages(sessionId: session.id)

    #expect(loaded.count == 1)
    #expect(loaded[0].text == message.text)
    #expect(loaded[0].citations == [citation])
}

@Test("Model install state roundtrip")
func modelInstallStateRoundTrip() async throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")

    let repository = try SQLiteRepository(databaseURL: tempDB)
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let state = ModelInstallationState(
        modelId: "mlx-community/parakeet-tdt-0.6b-v3",
        status: .ready,
        progress: 1.0,
        localPath: "/tmp/model.txt",
        lastError: nil
    )
    try await repository.saveModelInstallState(state)

    let loaded = try await repository.loadModelInstallState(modelId: state.modelId)
    #expect(loaded?.status == .ready)
    #expect(loaded?.progress == 1.0)
    #expect(loaded?.localPath == state.localPath)
}

@Test("HTTP retry policy retries 429 and succeeds")
func httpRetryPolicyRetriesOn429() async throws {
    let counter = AttemptCounter()
    let url = URL(string: "https://example.com/retry")!

    let result = try await HTTPRetryPolicy.execute(
        configuration: .init(maxAttempts: 4, baseDelaySeconds: 0.001, maxDelaySeconds: 0.003)
    ) {
        let attempt = counter.next()
        let status = attempt < 3 ? 429 : 200
        let headers = status == 429 ? ["Retry-After": "0"] : nil
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data("ok".utf8), response)
    }

    #expect(result.1.statusCode == 200)
    #expect(counter.current() == 3)
}

@Test("HTTP retry policy retries transient transport failure")
func httpRetryPolicyRetriesOnTransportError() async throws {
    let counter = AttemptCounter()
    let url = URL(string: "https://example.com/network")!

    let result = try await HTTPRetryPolicy.execute(
        configuration: .init(maxAttempts: 3, baseDelaySeconds: 0.001, maxDelaySeconds: 0.003)
    ) {
        let attempt = counter.next()
        if attempt == 1 {
            throw URLError(.timedOut)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("ok".utf8), response)
    }

    #expect(result.1.statusCode == 200)
    #expect(counter.current() == 2)
}

@Test("Database format inspector detects plaintext sqlite header")
func databaseFormatInspectorDetectsPlaintextSQLite() throws {
    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: tempDB) }

    let header = Data("SQLite format 3\0".utf8)
    try header.write(to: tempDB)

    let format = DatabaseFormatInspector.inspect(at: tempDB)
    #expect(format == .plaintextSQLite)
}

@Test("Database encryption state store roundtrip")
func databaseEncryptionStateStoreRoundTrip() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configURL = tempDir.appendingPathComponent("database-security.json")
    let store = DatabaseEncryptionStateStore(configURL: configURL)
    try store.save(encryptionEnabled: true)
    #expect(store.load(defaultValue: false) == true)
    try store.save(encryptionEnabled: false)
    #expect(store.load(defaultValue: true) == false)
}

@Test("SQLCipher runtime is available when linked")
func sqlCipherRuntimeAvailable() {
    #expect(SQLCipherSupport.runtimeIsAvailable() == true)
}

@Test("SQLCipher migration plaintext to encrypted preserves data")
func sqlCipherMigrationPlaintextToEncryptedPreservesData() async throws {
    #expect(SQLCipherSupport.runtimeIsAvailable() == true)

    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")
    defer { cleanupDatabaseFiles(at: tempDB) }

    let sessionId: UUID
    do {
        let repository = try SQLiteRepository(databaseURL: tempDB, encryptionMode: .disabled)
        sessionId = try await seedMigrationFixture(repository: repository, sessionName: "Migration Plain -> Encrypted")
    }

    #expect(DatabaseFormatInspector.inspect(at: tempDB) == .plaintextSQLite)

    try SQLCipherMigrator.migrateDatabase(
        at: tempDB,
        direction: .plaintextToEncrypted,
        keyHex: migrationTestKeyHex
    )

    #expect(DatabaseFormatInspector.inspect(at: tempDB) == .nonSQLite)

    let encryptedRepository = try SQLiteRepository(
        databaseURL: tempDB,
        encryptionMode: .sqlcipher(keyHex: migrationTestKeyHex)
    )
    try await assertMigrationFixture(
        repository: encryptedRepository,
        sessionId: sessionId,
        expectedSessionName: "Migration Plain -> Encrypted"
    )
}

@Test("SQLCipher migration encrypted to plaintext preserves data")
func sqlCipherMigrationEncryptedToPlaintextPreservesData() async throws {
    #expect(SQLCipherSupport.runtimeIsAvailable() == true)

    let tempDB = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString).sqlite")
    defer { cleanupDatabaseFiles(at: tempDB) }

    let sessionId: UUID
    do {
        let repository = try SQLiteRepository(
            databaseURL: tempDB,
            encryptionMode: .sqlcipher(keyHex: migrationTestKeyHex)
        )
        sessionId = try await seedMigrationFixture(repository: repository, sessionName: "Migration Encrypted -> Plain")
    }

    #expect(DatabaseFormatInspector.inspect(at: tempDB) == .nonSQLite)

    try SQLCipherMigrator.migrateDatabase(
        at: tempDB,
        direction: .encryptedToPlaintext,
        keyHex: migrationTestKeyHex
    )

    #expect(DatabaseFormatInspector.inspect(at: tempDB) == .plaintextSQLite)

    let plaintextRepository = try SQLiteRepository(databaseURL: tempDB, encryptionMode: .disabled)
    try await assertMigrationFixture(
        repository: plaintextRepository,
        sessionId: sessionId,
        expectedSessionName: "Migration Encrypted -> Plain"
    )
}

@Test("AppSettings decodes legacy Azure apiVersion into split fields")
func appSettingsLegacyAzureVersionMigration() throws {
    let legacyJSON = """
    {
      "onboardingCompleted": true,
      "theme": "system",
      "azureConfig": {
        "endpoint": "https://example.cognitiveservices.azure.com",
        "apiVersion": "2024-12-01-preview",
        "apiKeyRef": "azure-openai-api-key",
        "transcriptionDeployment": "whisper",
        "summaryDeployment": "gpt-4.1",
        "chatDeployment": "gpt-4.1"
      },
      "summaryPrompt": {
        "template": "custom"
      },
      "autoSummarizeAfterStop": true,
      "encryptionEnabled": false
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
    #expect(settings.azureConfig.chatAPIVersion == "2024-12-01-preview")
    #expect(settings.azureConfig.transcriptionAPIVersion == "2024-12-01-preview")
    #expect(settings.appLanguagePreference == .system)
    #expect(settings.cloudProvider == .azureOpenAI)
    #expect(settings.transcriptDefaultCollapsed == false)
    #expect(settings.lmStudioConfig.endpoint == LMStudioConfig.default.endpoint)
    #expect(settings.lmStudioConfig.apiKeyRef == LMStudioConfig.default.apiKeyRef)
}

@Test("AppSettings legacy local runtime fields remain decodable")
func appSettingsLegacyLocalRuntimeFieldsDecodable() throws {
    let legacyJSON = """
    {
      "onboardingCompleted": true,
      "theme": "system",
      "appLanguagePreference": "system",
      "cloudProvider": "azureOpenAI",
      "transcriptionConfig": {
        "providerType": "localVoxtral",
        "languageMode": { "auto": { "preferred": ["nl", "en"] } },
        "realtimeEnabled": true,
        "audioCaptureMode": "microphoneAndSystem",
        "localRealtimeEndpoint": "ws://127.0.0.1:8000/v1/realtime",
        "transcriptionDelayMs": 480,
        "localRuntimeLaunchCommand": "python3 scripts/parakeet_mlx_realtime_server.py",
        "localRuntimeWorkingDirectory": "/tmp",
        "localModelRef": {
          "modelId": "mlx-community/parakeet-tdt-0.6b-v3",
          "manifestURL": "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3",
          "checksumSHA256": null
        }
      },
      "azureConfig": {
        "endpoint": "",
        "chatAPIVersion": "2025-01-01-preview",
        "transcriptionAPIVersion": "2024-06-01",
        "apiKeyRef": "azure-openai-api-key",
        "transcriptionDeployment": "whisper",
        "summaryDeployment": "gpt-4.1",
        "chatDeployment": "gpt-4.1"
      },
      "openAIConfig": {
        "baseURL": "https://api.openai.com/v1",
        "apiKeyRef": "openai-api-key",
        "chatModel": "gpt-4.1",
        "summaryModel": "gpt-4.1",
        "transcriptionModel": "whisper-1"
      },
      "summaryPrompt": {
        "template": "custom"
      },
      "autoSummarizeAfterStop": true,
      "encryptionEnabled": false,
      "transcriptDefaultCollapsed": false
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
    #expect(settings.transcriptionConfig.providerType == .localVoxtral)
    #expect(settings.transcriptionConfig.localRealtimeEndpoint == "ws://127.0.0.1:8000/v1/realtime")
    #expect(settings.transcriptionConfig.localRuntimeLaunchCommand == "python3 scripts/parakeet_mlx_realtime_server.py")
    #expect(settings.lmStudioConfig.endpoint == LMStudioConfig.default.endpoint)
}

@Test("Cloud provider decodes LM Studio")
func appSettingsCloudProviderLMStudioDecodable() throws {
    let json = """
    {
      "onboardingCompleted": true,
      "theme": "system",
      "appLanguagePreference": "system",
      "cloudProvider": "lmStudio",
      "transcriptionConfig": {
        "providerType": "localVoxtral",
        "languageMode": { "auto": { "preferred": ["nl", "en"] } },
        "realtimeEnabled": false,
        "audioCaptureMode": "microphoneOnly",
        "localRealtimeEndpoint": "ws://127.0.0.1:8000/v1/realtime",
        "transcriptionDelayMs": 480
      },
      "azureConfig": {
        "endpoint": "",
        "chatAPIVersion": "2025-01-01-preview",
        "transcriptionAPIVersion": "2024-06-01",
        "apiKeyRef": "azure-openai-api-key",
        "transcriptionDeployment": "whisper",
        "summaryDeployment": "gpt-4.1",
        "chatDeployment": "gpt-4.1"
      },
      "openAIConfig": {
        "baseURL": "https://api.openai.com/v1",
        "apiKeyRef": "openai-api-key",
        "chatModel": "gpt-4.1",
        "summaryModel": "gpt-4.1",
        "transcriptionModel": "whisper-1"
      },
      "lmStudioConfig": {
        "endpoint": "http://127.0.0.1:1234",
        "apiKeyRef": "lmstudio-api-key",
        "selectedModelIdentifier": "local-model"
      },
      "summaryPrompt": {
        "template": "custom"
      },
      "autoSummarizeAfterStop": true,
      "encryptionEnabled": false,
      "transcriptDefaultCollapsed": false
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.cloudProvider == .lmStudio)
    #expect(settings.lmStudioConfig.selectedModelIdentifier == "local-model")
}

@Test("Summary prompt normalization keeps custom and upgrades legacy")
func summaryPromptNormalization() {
    let legacy = SummaryPrompt(template: """
You are a meeting notes assistant.
Write concise, factual output in English.
Use this exact format:
1) Executive summary (max 6 bullets)
2) Decisions
3) Action items (bullet: task | owner | deadline or "unknown")
4) Open questions
5) Next steps (next 7 days)
Rules:
- Use only information from the transcript.
- Include time references as [mm:ss-mm:ss] whenever possible.
- If something is missing, explicitly write "Unknown".
""")

    let custom = SummaryPrompt(template: "My custom prompt.")

    #expect(legacy.normalizedAgainstKnownDefaults() == .defaultPrompt)
    #expect(custom.normalizedAgainstKnownDefaults() == custom)
}

@Test("LM Studio loaded model parser handles loaded_instances")
func lmStudioLoadedModelParser() throws {
    let json = """
    {
      "data": [
        {
          "id": "meta-llama-3",
          "name": "Meta Llama 3 8B",
          "loaded_instances": [
            { "id": "instance-1", "identifier": "meta-llama-3-8b-instruct" }
          ]
        },
        {
          "id": "mistral-7b",
          "name": "Mistral 7B",
          "loaded_instances": []
        }
      ]
    }
    """

    let models = try LMStudioRuntimeClient.parseLoadedModels(from: Data(json.utf8))
    #expect(models.count == 1)
    #expect(models[0].identifier == "meta-llama-3-8b-instruct")
}

@Test("Waveform smoothing helper is deterministic")
func waveformSmoothingDeterministic() {
    let rising = AppViewModel.smoothedWaveformLevel(current: 0.1, target: 0.9, riseAlpha: 0.5, fallAlpha: 0.2)
    let falling = AppViewModel.smoothedWaveformLevel(current: 0.9, target: 0.1, riseAlpha: 0.5, fallAlpha: 0.2)

    #expect(abs(rising - 0.5) < 0.0001)
    #expect(abs(falling - 0.74) < 0.0001)
}

@Test("Language resolver respects system and explicit preferences")
func appLanguageResolver() {
    #expect(
        AppLanguageResolver.resolveLanguageCode(
            preference: .system,
            preferredLanguages: ["nl-BE", "en-US"]
        ) == "nl"
    )
    #expect(
        AppLanguageResolver.resolveLanguageCode(
            preference: .system,
            preferredLanguages: ["fr-FR", "de-DE"]
        ) == "en"
    )
    #expect(AppLanguageResolver.resolveLanguageCode(preference: .english) == "en")
    #expect(AppLanguageResolver.resolveLanguageCode(preference: .dutch) == "nl")
}

@Test("Azure endpoint parser fills chat and transcription fields")
func azureEndpointPasteParserRoundTrip() {
    let chatURL = "https://demo.cognitiveservices.azure.com/openai/deployments/gpt-4.1/chat/completions?api-version=2025-01-01-preview"
    let whisperURL = "https://demo.cognitiveservices.azure.com/openai/deployments/whisper/audio/translations?api-version=2024-06-01"
    let result = AzureEndpointPasteParser.parse("\(chatURL) \(whisperURL)")

    #expect(result.didParseAny == true)
    #expect(result.endpoint == "https://demo.cognitiveservices.azure.com")
    #expect(result.chatDeployment == "gpt-4.1")
    #expect(result.transcriptionDeployment == "whisper")
    #expect(result.chatAPIVersion == "2025-01-01-preview")
    #expect(result.transcriptionAPIVersion == "2024-06-01")
    #expect(result.usedTranslationsRoute == true)
}
