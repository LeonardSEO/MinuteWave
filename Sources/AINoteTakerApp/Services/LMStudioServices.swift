import Foundation
import AppKit

struct LMStudioLoadedModel: Equatable, Identifiable, Sendable {
    var identifier: String
    var displayName: String

    var id: String { identifier }
}

struct LMStudioRuntimeSnapshot: Equatable, Sendable {
    var isInstalled: Bool
    var applicationURL: URL?
    var isServerReachable: Bool
    var loadedModels: [LMStudioLoadedModel]
    var errorMessage: String?

    var canRunInference: Bool {
        isServerReachable && !loadedModels.isEmpty
    }
}

struct LMStudioRuntimeClient {
    static let appBundleIdentifier = "ai.elementlabs.lmstudio"
    static let appPathFallback = "/Applications/LM Studio.app"

    private let session: URLSession

    init(session: URLSession = LMStudioRuntimeClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }

    func installedApplicationURL(fileManager: FileManager = .default) -> URL? {
        if let byBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) {
            return byBundle
        }

        let fallback = URL(fileURLWithPath: Self.appPathFallback)
        if fileManager.fileExists(atPath: fallback.path) {
            return fallback
        }

        return nil
    }

    func inspectRuntime(config: LMStudioConfig) async -> LMStudioRuntimeSnapshot {
        let appURL = installedApplicationURL()
        let isInstalled = appURL != nil

        do {
            let loadedModels = try await fetchLoadedModels(config: config)
            return LMStudioRuntimeSnapshot(
                isInstalled: isInstalled,
                applicationURL: appURL,
                isServerReachable: true,
                loadedModels: loadedModels,
                errorMessage: nil
            )
        } catch {
            return LMStudioRuntimeSnapshot(
                isInstalled: isInstalled,
                applicationURL: appURL,
                isServerReachable: false,
                loadedModels: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    func resolveModelIdentifier(config: LMStudioConfig) async throws -> String {
        let loadedModels = try await fetchLoadedModels(config: config)
        guard !loadedModels.isEmpty else {
            throw AppError.providerUnavailable(reason: L10n.tr("error.lmstudio.no_loaded_models"))
        }

        let preferred = config.selectedModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty,
           loadedModels.contains(where: { $0.identifier == preferred }) {
            return preferred
        }

        return loadedModels[0].identifier
    }

    func fetchLoadedModels(config: LMStudioConfig) async throws -> [LMStudioLoadedModel] {
        guard let url = modelsEndpointURL(baseURL: config.endpoint) else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.lmstudio.endpoint_invalid"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, http) = try await HTTPRetryPolicy.send(
            request: request,
            session: session,
            configuration: HTTPRetryPolicy.azureDefault
        )

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppError.networkFailure(reason: L10n.tr("error.lmstudio.models_http", http.statusCode, body))
        }

        return try Self.parseLoadedModels(from: data)
    }

    func modelsEndpointURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false else {
            return nil
        }

        var path = components.path
        if path.isEmpty {
            path = "/api/v1/models"
        } else if path.hasSuffix("/") {
            path.removeLast()
        }

        if path.hasSuffix("/api/v1/models") {
            // keep as-is
        } else if path.hasSuffix("/api/v1") {
            path += "/models"
        } else {
            path += "/api/v1/models"
        }

        components.path = path
        return components.url
    }

    static func parseLoadedModels(from data: Data) throws -> [LMStudioLoadedModel] {
        let envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        let modelEntries = envelope.data ?? envelope.models ?? []

        var loaded: [LMStudioLoadedModel] = []
        var seen = Set<String>()

        for entry in modelEntries {
            let preferredDisplay = firstNonEmpty(entry.name, entry.id, entry.modelKey, entry.identifier, entry.path) ?? "Model"

            if let instances = entry.loadedInstances, !instances.isEmpty {
                for instance in instances {
                    guard let identifier = firstNonEmpty(instance.identifier, instance.id, entry.id, entry.modelKey, entry.name, entry.path),
                          seen.contains(identifier) == false else {
                        continue
                    }
                    seen.insert(identifier)
                    let display = firstNonEmpty(instance.name, preferredDisplay, identifier) ?? identifier
                    loaded.append(LMStudioLoadedModel(identifier: identifier, displayName: display))
                }
                continue
            }

            let state = (entry.state ?? entry.status ?? "").lowercased()
            if state == "loaded",
               let identifier = firstNonEmpty(entry.id, entry.modelKey, entry.identifier, entry.path),
               seen.contains(identifier) == false {
                seen.insert(identifier)
                loaded.append(LMStudioLoadedModel(identifier: identifier, displayName: preferredDisplay))
            }
        }

        return loaded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private struct ModelsEnvelope: Decodable {
        var data: [ModelEntry]?
        var models: [ModelEntry]?
    }

    private struct ModelEntry: Decodable {
        var id: String?
        var name: String?
        var modelKey: String?
        var identifier: String?
        var path: String?
        var state: String?
        var status: String?
        var loadedInstances: [LoadedInstance]?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case modelKey = "model_key"
            case identifier
            case path
            case state
            case status
            case loadedInstances = "loaded_instances"
        }
    }

    private struct LoadedInstance: Decodable {
        var id: String?
        var name: String?
        var identifier: String?
    }
}

struct LMStudioOpenAICompatClient {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func validateConfig(_ config: LMStudioConfig) throws {
        guard config.isConfigured else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.lmstudio.config_incomplete"))
        }

        let trimmed = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.lmstudio.endpoint_invalid"))
        }
    }

    func performChatCompletionCall(
        config: LMStudioConfig,
        model: String,
        messages: [[String: String]],
        maxCompletionTokens: Int = 2048,
        temperature: Double = 0.2
    ) async throws -> String {
        try validateConfig(config)

        guard let url = chatCompletionURL(baseURL: config.endpoint) else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.lmstudio.chat_url_invalid"))
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_completion_tokens": maxCompletionTokens,
            "temperature": temperature
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = try apiKeyIfPresent(config: config), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, http) = try await HTTPRetryPolicy.send(
            request: request,
            configuration: HTTPRetryPolicy.azureDefault
        )

        switch http.statusCode {
        case 200...299:
            return extractChatCompletionText(data: data)
        case 401, 403:
            throw AppError.networkFailure(reason: L10n.tr("error.lmstudio.auth_failed", http.statusCode))
        case 429:
            throw AppError.networkFailure(reason: L10n.tr("error.lmstudio.rate_limited"))
        default:
            let serverText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.networkFailure(reason: L10n.tr("error.lmstudio.http", http.statusCode, serverText))
        }
    }

    func chatCompletionURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        var path = components.path
        if path.isEmpty {
            path = "/v1/chat/completions"
        } else if path.hasSuffix("/") {
            path.removeLast()
        }

        if path.hasSuffix("/v1/chat/completions") {
            // keep as-is
        } else if path.hasSuffix("/v1") {
            path += "/chat/completions"
        } else {
            path += "/v1/chat/completions"
        }

        components.path = path
        return components.url
    }

    private func apiKeyIfPresent(config: LMStudioConfig) throws -> String? {
        let keyRef = config.apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyRef.isEmpty else { return nil }
        return try keychain.get(keyRef)
    }

    private func extractChatCompletionText(data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        if let choices = obj["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any] {
            if let text = message["content"] as? String, !text.isEmpty {
                return text
            }
            if let parts = message["content"] as? [[String: Any]] {
                let stitched = parts.compactMap { $0["text"] as? String }.joined()
                if !stitched.isEmpty {
                    return stitched
                }
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class LMStudioSummarizationProvider: SummarizationProvider, @unchecked Sendable {
    private let runtimeClient: LMStudioRuntimeClient
    private let client: LMStudioOpenAICompatClient
    private let settingsProvider: @Sendable () async throws -> AppSettings

    init(
        runtimeClient: LMStudioRuntimeClient = LMStudioRuntimeClient(),
        client: LMStudioOpenAICompatClient = LMStudioOpenAICompatClient(),
        settingsProvider: @escaping @Sendable () async throws -> AppSettings
    ) {
        self.runtimeClient = runtimeClient
        self.client = client
        self.settingsProvider = settingsProvider
    }

    func summarize(transcript: Transcript, prompt: SummaryPrompt) async throws -> MeetingSummary {
        let settings = try await settingsProvider()
        let config = settings.lmStudioConfig
        let model = try await runtimeClient.resolveModelIdentifier(config: config)

        let response = try await client.performChatCompletionCall(
            config: config,
            model: model,
            messages: [
                ["role": "system", "content": prompt.template],
                ["role": "user", "content": "Transcript:\n\(transcript.plainText)"]
            ],
            maxCompletionTokens: 4096,
            temperature: 0.1
        )

        return MeetingSummary(
            title: "Auto summary \(Date().formatted(date: .abbreviated, time: .shortened))",
            executiveSummary: response,
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

final class LMStudioTranscriptChatProvider: TranscriptChatProvider, @unchecked Sendable {
    private let runtimeClient: LMStudioRuntimeClient
    private let client: LMStudioOpenAICompatClient
    private let repository: SessionRepository

    init(
        runtimeClient: LMStudioRuntimeClient = LMStudioRuntimeClient(),
        client: LMStudioOpenAICompatClient = LMStudioOpenAICompatClient(),
        repository: SessionRepository
    ) {
        self.runtimeClient = runtimeClient
        self.client = client
        self.repository = repository
    }

    func answer(question: String, transcriptId: UUID, strategy: RetrievalStrategy) async throws -> ChatAnswer {
        let settings = try await repository.loadSettings()
        let segments = try await repository.listSegments(sessionId: transcriptId)
        let model = try await runtimeClient.resolveModelIdentifier(config: settings.lmStudioConfig)

        let selected = retrieveSegments(question: question, segments: segments, strategy: strategy)
        let context = selected.map { "[\($0.startMs)-\($0.endMs)] \($0.text)" }.joined(separator: "\n")

        let text = try await client.performChatCompletionCall(
            config: settings.lmStudioConfig,
            model: model,
            messages: [
                [
                    "role": "system",
                    "content": L10n.tr("prompt.chat.system")
                ],
                [
                    "role": "user",
                    "content": "Vraag: \(question)\n\nContext:\n\(context)"
                ]
            ],
            maxCompletionTokens: 2048,
            temperature: 0.2
        )

        let citations = selected.map {
            TranscriptCitation(segmentId: $0.id, startMs: $0.startMs, endMs: $0.endMs)
        }

        return ChatAnswer(text: text, citations: citations)
    }

    private func retrieveSegments(question: String, segments: [TranscriptSegment], strategy: RetrievalStrategy) -> [TranscriptSegment] {
        guard strategy == .lexicalTopK else { return Array(segments.prefix(6)) }
        let queryTokens = tokenize(question)

        let scored = segments.map { segment -> (TranscriptSegment, Int) in
            let score = overlapCount(lhs: queryTokens, rhs: tokenize(segment.text))
            return (segment, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.startMs < rhs.0.startMs
            }
            return lhs.1 > rhs.1
        }

        let top = scored.prefix(6).map(\.0)
        return top.isEmpty ? Array(segments.prefix(6)) : top
    }

    private func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private func overlapCount(lhs: Set<String>, rhs: Set<String>) -> Int {
        lhs.intersection(rhs).count
    }
}
