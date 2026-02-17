import Foundation

struct AzureResponsesClient {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func validateConfig(_ config: AzureConfig) throws {
        guard config.isChatConfigured else {
            throw AppError.invalidConfiguration(reason: "Azure configuration is incomplete.")
        }

        let trimmed = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false else {
            throw AppError.invalidConfiguration(reason: "Azure endpoint must be a valid https URL.")
        }
    }

    func performChatCompletionCall(
        config: AzureConfig,
        deployment: String,
        messages: [[String: String]],
        maxCompletionTokens: Int = 2048,
        temperature: Double = 0.2
    ) async throws -> String {
        try validateConfig(config)

        guard let apiKey = try keychain.get(config.apiKeyRef), !apiKey.isEmpty else {
            throw AppError.invalidConfiguration(reason: "Azure API key is missing in Keychain for key '\(config.apiKeyRef)'.")
        }

        guard var components = URLComponents(string: config.endpoint) else {
            throw AppError.invalidConfiguration(reason: "Could not parse Azure endpoint.")
        }

        components.path = "/openai/deployments/\(deployment)/chat/completions"
        components.queryItems = [URLQueryItem(name: "api-version", value: config.chatAPIVersion)]

        guard let url = components.url else {
            throw AppError.invalidConfiguration(reason: "Could not build Azure Chat Completions URL.")
        }

        let payload: [String: Any] = [
            "model": deployment,
            "messages": messages,
            "max_completion_tokens": maxCompletionTokens,
            "temperature": temperature
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")

        let (data, http) = try await HTTPRetryPolicy.send(
            request: request,
            configuration: HTTPRetryPolicy.azureDefault
        )

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw AppError.networkFailure(reason: "Azure authentication failed (\(http.statusCode)).")
        case 429:
            throw AppError.networkFailure(reason: "Azure rate limit reached (429).")
        default:
            let serverText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.networkFailure(reason: "Azure error \(http.statusCode): \(serverText)")
        }

        return extractChatCompletionText(data: data)
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

final class AzureSummarizationProvider: SummarizationProvider, @unchecked Sendable {
    private let client: AzureResponsesClient
    private let settingsProvider: @Sendable () async throws -> AppSettings

    init(
        client: AzureResponsesClient = AzureResponsesClient(),
        settingsProvider: @escaping @Sendable () async throws -> AppSettings
    ) {
        self.client = client
        self.settingsProvider = settingsProvider
    }

    func summarize(transcript: Transcript, prompt: SummaryPrompt) async throws -> MeetingSummary {
        let settings = try await settingsProvider()
        let config = settings.azureConfig

        let response = try await client.performChatCompletionCall(
            config: config,
            deployment: config.summaryDeployment,
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

final class AzureTranscriptChatProvider: TranscriptChatProvider, @unchecked Sendable {
    private let client: AzureResponsesClient
    private let repository: SessionRepository

    init(client: AzureResponsesClient = AzureResponsesClient(), repository: SessionRepository) {
        self.client = client
        self.repository = repository
    }

    func answer(question: String, transcriptId: UUID, strategy: RetrievalStrategy) async throws -> ChatAnswer {
        let settings = try await repository.loadSettings()
        let segments = try await repository.listSegments(sessionId: transcriptId)

        let selected = retrieveSegments(question: question, segments: segments, strategy: strategy)
        let context = selected.map { "[\($0.startMs)-\($0.endMs)] \($0.text)" }.joined(separator: "\n")

        let text = try await client.performChatCompletionCall(
            config: settings.azureConfig,
            deployment: settings.azureConfig.chatDeployment,
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

        let top = scored.prefix(6).map(\ .0)
        return top.isEmpty ? Array(segments.prefix(6)) : top
    }

    private func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private func overlapCount(lhs: Set<String>, rhs: Set<String>) -> Int {
        lhs.intersection(rhs).count
    }
}
