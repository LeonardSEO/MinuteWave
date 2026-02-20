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

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: ((URLRequest) -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.requestHandler
        Self.lock.unlock()

        let result: (HTTPURLResponse, Data)
        if let handler {
            result = handler(request)
        } else {
            let fallbackURL = request.url ?? URL(string: "https://example.invalid")!
            let response = HTTPURLResponse(url: fallbackURL, statusCode: 500, httpVersion: nil, headerFields: nil)!
            result = (response, Data())
        }

        client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let migrationTestKeyHex = String(repeating: "ab", count: 48)

private func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func cleanupDatabaseFiles(at databaseURL: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: databaseURL)
    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
}

private func makeOpenAITranscriptionConfig(baseURL: String) -> TranscriptionConfig {
    TranscriptionConfig(
        providerType: .openAI,
        languageMode: .auto(preferred: ["en"]),
        realtimeEnabled: false,
        audioCaptureMode: .microphoneOnly,
        localRealtimeEndpoint: "ws://127.0.0.1:8000/v1/realtime",
        transcriptionDelayMs: 480,
        localRuntimeLaunchCommand: nil,
        localRuntimeWorkingDirectory: nil,
        azureConfig: nil,
        openAIConfig: OpenAIConfig(
            baseURL: baseURL,
            apiKeyRef: "openai-api-key",
            chatModel: OpenAIModelPolicy.chatModel,
            summaryModel: OpenAIModelPolicy.summaryModel,
            transcriptionModel: OpenAIModelPolicy.transcriptionModel
        ),
        localModelRef: nil
    )
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

@Test("Semantic version parser normalizes Git tags")
func semanticVersionParserNormalizesGitTags() {
    #expect(AppSemanticVersion("v0.1.10-beta.1")?.description == "0.1.10")
    #expect(AppSemanticVersion(" 1.2.3 ")?.description == "1.2.3")
    #expect(AppSemanticVersion("release-1.2.3") == nil)
}

@Test("Semantic version comparison handles varying component lengths")
func semanticVersionComparisonHandlesComponentLengths() {
    guard
        let v010 = AppSemanticVersion("0.1.10"),
        let v019 = AppSemanticVersion("0.1.9"),
        let v12 = AppSemanticVersion("1.2"),
        let v120 = AppSemanticVersion("1.2.0"),
        let v121 = AppSemanticVersion("1.2.1")
    else {
        Issue.record("Failed to parse one of the test semantic versions")
        return
    }

    #expect(v010 > v019)
    #expect(v12 == v120)
    #expect(v12 < v121)
}

@Test("OpenAI endpoint policy only allows HTTPS URLs with host")
func openAIEndpointPolicyRequiresHTTPS() {
    #expect(OpenAIEndpointPolicy.validateHTTPSBaseURL("https://api.openai.com/v1") == true)
    #expect(OpenAIEndpointPolicy.validateHTTPSBaseURL("http://api.openai.com/v1") == false)
    #expect(OpenAIEndpointPolicy.validateHTTPSBaseURL("https:///v1") == false)
}

@Test("OpenAI client validation rejects non-HTTPS base URL")
func openAIResponsesClientValidationRejectsHTTP() {
    let client = OpenAIResponsesClient()
    let config = OpenAIConfig(
        baseURL: "http://api.openai.com/v1",
        apiKeyRef: "openai-api-key",
        chatModel: OpenAIModelPolicy.chatModel,
        summaryModel: OpenAIModelPolicy.summaryModel,
        transcriptionModel: OpenAIModelPolicy.transcriptionModel
    )

    var rejected = false
    do {
        try client.validateConfig(config)
    } catch let error as AppError {
        if case .invalidConfiguration = error {
            rejected = true
        }
    } catch {}
    #expect(rejected == true)
}

@Test("OpenAI transcription start rejects non-HTTPS configuration")
func openAITranscriptionStartRejectsHTTPBaseURL() async {
    let provider = OpenAITranscriptionProvider()
    let config = makeOpenAITranscriptionConfig(baseURL: "http://api.openai.com/v1")

    var rejected = false
    do {
        try await provider.startSession(config: config, sessionId: UUID())
    } catch let error as AppError {
        if case .invalidConfiguration = error {
            rejected = true
        }
    } catch {}
    #expect(rejected == true)
}

@Test("Trusted release URL policy only allows GitHub releases path for owner/repo")
func trustedReleaseURLPolicyRestrictsHostAndPath() throws {
    let trusted = try #require(URL(string: "https://github.com/LeonardSEO/MinuteWave/releases/tag/v1.2.3"))
    let wrongHost = try #require(URL(string: "https://example.com/LeonardSEO/MinuteWave/releases/tag/v1.2.3"))
    let wrongPath = try #require(URL(string: "https://github.com/LeonardSEO/MinuteWave/pulls/10"))
    let wrongRepo = try #require(URL(string: "https://github.com/LeonardSEO/OtherRepo/releases"))
    let insecure = try #require(URL(string: "http://github.com/LeonardSEO/MinuteWave/releases"))

    #expect(TrustedReleaseURLPolicy.isTrustedReleaseURL(trusted, owner: "LeonardSEO", repository: "MinuteWave") == true)
    #expect(TrustedReleaseURLPolicy.isTrustedReleaseURL(wrongHost, owner: "LeonardSEO", repository: "MinuteWave") == false)
    #expect(TrustedReleaseURLPolicy.isTrustedReleaseURL(wrongPath, owner: "LeonardSEO", repository: "MinuteWave") == false)
    #expect(TrustedReleaseURLPolicy.isTrustedReleaseURL(wrongRepo, owner: "LeonardSEO", repository: "MinuteWave") == false)
    #expect(TrustedReleaseURLPolicy.isTrustedReleaseURL(insecure, owner: "LeonardSEO", repository: "MinuteWave") == false)
}

@Test("GitHub update service falls back when API payload release URL is untrusted")
@MainActor
func gitHubUpdateServiceFallsBackForUntrustedPayloadURL() async {
    let payload = """
    {
      "tag_name": "v9.9.9",
      "html_url": "https://malicious.example/release",
      "draft": false,
      "prerelease": false
    }
    """
    StubURLProtocol.setHandler { request in
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(payload.utf8))
    }
    defer { StubURLProtocol.setHandler(nil) }

    let service = GitHubUpdateService(
        owner: "LeonardSEO",
        repository: "MinuteWave",
        session: makeStubbedSession()
    )
    await service.checkForUpdates(userInitiated: false)

    #expect(service.latestReleaseURL == service.fallbackReleasesPageURL)
}

@Test("Model registry policy accepts trusted host and rejects untrusted overrides")
func modelRegistryPolicyResolveTrustedBaseURL() {
    let trusted = ModelRegistryPolicy.resolveTrustedBaseURL(candidate: "https://huggingface.co")
    #expect(trusted.baseURL == ModelRegistryPolicy.trustedDefaultBaseURL)
    #expect(trusted.warning == nil)

    let withPath = ModelRegistryPolicy.resolveTrustedBaseURL(candidate: "https://huggingface.co/path")
    #expect(withPath.baseURL == ModelRegistryPolicy.trustedDefaultBaseURL)
    #expect(withPath.warning != nil)

    let insecure = ModelRegistryPolicy.resolveTrustedBaseURL(candidate: "http://huggingface.co")
    #expect(insecure.baseURL == ModelRegistryPolicy.trustedDefaultBaseURL)
    #expect(insecure.warning != nil)

    let wrongHost = ModelRegistryPolicy.resolveTrustedBaseURL(candidate: "https://example.com")
    #expect(wrongHost.baseURL == ModelRegistryPolicy.trustedDefaultBaseURL)
    #expect(wrongHost.warning != nil)
}

@Test("Model integrity verifier bootstraps baseline and verifies unchanged files")
func modelIntegrityVerifierBootstrapsAndVerifies() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repoDir = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    let modelFile = repoDir.appendingPathComponent("model.bin")
    try Data("v1".utf8).write(to: modelFile)

    let verifier = ModelIntegrityVerifier(
        manifestURL: tempDir.appendingPathComponent("model-integrity-manifest.json")
    )
    let repository = ModelIntegrityVerifier.RepositoryInput(
        repositoryId: "test/repo",
        rootDirectory: repoDir,
        expectedRelativePaths: ["model.bin"]
    )

    let firstResult = try verifier.verifyOrBootstrap([repository])
    #expect(firstResult["test/repo"] == .bootstrapped)

    let secondResult = try verifier.verifyOrBootstrap([repository])
    #expect(secondResult["test/repo"] == .verified)
}

@Test("Model integrity verifier blocks mismatched model files after baseline")
func modelIntegrityVerifierDetectsMismatch() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-note-taker-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repoDir = tempDir.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    let modelFile = repoDir.appendingPathComponent("model.bin")
    try Data("v1".utf8).write(to: modelFile)

    let verifier = ModelIntegrityVerifier(
        manifestURL: tempDir.appendingPathComponent("model-integrity-manifest.json")
    )
    let repository = ModelIntegrityVerifier.RepositoryInput(
        repositoryId: "test/repo",
        rootDirectory: repoDir,
        expectedRelativePaths: ["model.bin"]
    )
    _ = try verifier.verifyOrBootstrap([repository])

    try Data("tampered".utf8).write(to: modelFile, options: .atomic)

    var mismatchDetected = false
    do {
        _ = try verifier.verifyOrBootstrap([repository])
    } catch let error as AppError {
        if case .providerUnavailable(let reason) = error {
            mismatchDetected = reason.localizedCaseInsensitiveContains("integrity mismatch")
        }
    } catch {}

    #expect(mismatchDetected == true)
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

@Test("AppSettings default enables encryption and legacy missing field decodes to true")
func appSettingsEncryptionDefaultsToEnabled() throws {
    #expect(AppSettings.default.encryptionEnabled == true)

    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(decoded.encryptionEnabled == true)
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

@Test("Screen capture quick state uses preflight only")
func screenCaptureQuickState() {
    #expect(Permissions.quickScreenCaptureState(preflightGranted: true) == .granted)
    #expect(Permissions.quickScreenCaptureState(preflightGranted: false) == .notDetermined)
}

@Test("Screen capture probe failure classification detects denied vs unknown")
func screenCaptureProbeFailureClassification() {
    let deniedError = NSError(
        domain: "SCStreamErrorDomain",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "User denied screen capture permission."]
    )
    #expect(Permissions.classifyScreenCaptureProbeFailure(deniedError) == .denied)

    let unknownError = NSError(
        domain: "NSCocoaErrorDomain",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "A generic stream setup failure occurred."]
    )
    #expect(Permissions.classifyScreenCaptureProbeFailure(unknownError) == .notDetermined)
}

@Test("Audio capture mode changes are blocked while recording-like statuses are active")
func audioCaptureModeChangeAllowedByStatus() {
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .idle) == true)
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .completed) == true)
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .failed) == true)
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .recording) == false)
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .paused) == false)
    #expect(AppViewModel.isAudioCaptureModeChangeAllowed(for: .finalizing) == false)
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

@Test("L10n unresolved key fallback never returns raw key")
func l10nUnresolvedKeyFallbackNeverLeaksRawKey() {
    let rawKey = "ui.missing.translation.key"
    let english = L10n.localizedString(for: rawKey, languageCode: "en")
    let dutch = L10n.localizedString(for: rawKey, languageCode: "nl")

    #expect(english != rawKey)
    #expect(dutch != rawKey)
    #expect(english == "Translation unavailable")
    #expect(dutch == "Vertaling ontbreekt")
}

@Test("Localized display mappings follow selected app language")
func localizedDisplayMappingsForDutchAndEnglish() {
    let previousCode = L10n.resolvedLanguageCode()
    defer { L10n.setResolvedLanguageCode(previousCode) }

    L10n.setResolvedLanguageCode("nl")
    #expect(SessionStatus.completed.localizedLabel == "Voltooid")
    #expect(ChatMessage.Role.user.localizedLabel == "Gebruiker")
    #expect(LocalAudioCaptureMode.microphoneOnly.localizedShortLabel == "Alleen microfoon")

    L10n.setResolvedLanguageCode("en")
    #expect(SessionStatus.completed.localizedLabel == "Completed")
    #expect(ChatMessage.Role.user.localizedLabel == "User")
    #expect(LocalAudioCaptureMode.microphoneOnly.localizedShortLabel == "Mic only")
}

@Test("Markdown summary parser falls back for malformed control input")
func markdownSummaryParserFallback() {
    #expect(MarkdownSummaryView.parseMarkdown("## Summary\n- one") != nil)
    #expect(MarkdownSummaryView.parseMarkdown("broken\u{0000}markdown") == nil)
}

@Test("Localization coverage for used keys in en and nl")
func localizationKeyCoverage() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceRoot = repoRoot.appendingPathComponent("Sources/AINoteTakerApp", isDirectory: true)
    let enStrings = repoRoot.appendingPathComponent("Sources/AINoteTakerApp/Resources/en.lproj/Localizable.strings")
    let nlStrings = repoRoot.appendingPathComponent("Sources/AINoteTakerApp/Resources/nl.lproj/Localizable.strings")

    let usedKeys = try extractLocalizationKeys(fromSwiftFilesIn: sourceRoot)
    let enKeys = try extractStringsKeys(from: enStrings)
    let nlKeys = try extractStringsKeys(from: nlStrings)

    let missingInEn = usedKeys.subtracting(enKeys)
    let missingInNl = usedKeys.subtracting(nlKeys)
    #expect(missingInEn.isEmpty, "Missing in en.lproj: \(missingInEn.sorted())")
    #expect(missingInNl.isEmpty, "Missing in nl.lproj: \(missingInNl.sorted())")
}

private func extractLocalizationKeys(fromSwiftFilesIn root: URL) throws -> Set<String> {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    let l10nPattern = try NSRegularExpression(
        pattern: #"L10n\.tr\(\s*"([^"]+)""#,
        options: [.dotMatchesLineSeparators]
    )
    let localizedStringKeyPattern = try NSRegularExpression(
        pattern: #"LocalizedStringKey\(\s*"([^"]+)""#,
        options: [.dotMatchesLineSeparators]
    )

    var result = Set<String>()
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in l10nPattern.matches(in: text, options: [], range: fullRange) {
            if let range = Range(match.range(at: 1), in: text) {
                result.insert(String(text[range]))
            }
        }
        for match in localizedStringKeyPattern.matches(in: text, options: [], range: fullRange) {
            if let range = Range(match.range(at: 1), in: text) {
                result.insert(String(text[range]))
            }
        }
    }
    return result
}

private func extractStringsKeys(from stringsFile: URL) throws -> Set<String> {
    let content = try String(contentsOf: stringsFile, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*="#, options: [.anchorsMatchLines])
    let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
    var keys = Set<String>()
    for match in pattern.matches(in: content, options: [], range: fullRange) {
        if let range = Range(match.range(at: 1), in: content) {
            keys.insert(String(content[range]))
        }
    }
    return keys
}
