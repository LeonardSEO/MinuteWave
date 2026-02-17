import Foundation

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum AppLanguagePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case dutch
    case english

    var id: String { rawValue }
}

enum CloudProviderType: String, CaseIterable, Codable, Identifiable {
    case azureOpenAI
    case openAI
    case lmStudio

    var id: String { rawValue }
}

enum TranscriptionProviderType: String, CaseIterable, Codable, Identifiable {
    case localVoxtral
    case azure
    case openAI

    var id: String { rawValue }
}

enum LocalAudioCaptureMode: String, CaseIterable, Codable, Identifiable {
    case microphoneOnly
    case microphoneAndSystem

    var id: String { rawValue }
}

enum SessionStatus: String, Codable {
    case idle
    case recording
    case paused
    case finalizing
    case completed
    case failed
}

enum SummaryStatus: String, Codable {
    case notStarted
    case processing
    case completed
    case failed
}

enum ModelInstallStatus: String, Codable {
    case notInstalled
    case downloading
    case verifying
    case ready
    case failed
}

enum LanguageMode: Codable, Equatable {
    case auto(preferred: [String])
    case fixed(code: String)
}

enum AzureModelPolicy {
    static let chatDeployment = "gpt-4.1"
    static let summaryDeployment = "gpt-4.1"
    static let transcriptionDeployment = "whisper"
    static let transcriptionModel = "whisper-1"
    static let defaultChatAPIVersion = "2025-01-01-preview"
    static let defaultTranscriptionAPIVersion = "2024-06-01"
}

struct AzureConfig: Codable, Equatable {
    var endpoint: String
    var chatAPIVersion: String
    var transcriptionAPIVersion: String
    var apiKeyRef: String
    var transcriptionDeployment: String
    var summaryDeployment: String
    var chatDeployment: String

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case chatAPIVersion
        case transcriptionAPIVersion
        case apiVersion
        case apiKeyRef
        case transcriptionDeployment
        case summaryDeployment
        case chatDeployment
    }

    static let empty = AzureConfig(
        endpoint: "",
        chatAPIVersion: AzureModelPolicy.defaultChatAPIVersion,
        transcriptionAPIVersion: AzureModelPolicy.defaultTranscriptionAPIVersion,
        apiKeyRef: "azure-openai-api-key",
        transcriptionDeployment: AzureModelPolicy.transcriptionDeployment,
        summaryDeployment: AzureModelPolicy.summaryDeployment,
        chatDeployment: AzureModelPolicy.chatDeployment
    )

    init(
        endpoint: String,
        chatAPIVersion: String,
        transcriptionAPIVersion: String,
        apiKeyRef: String,
        transcriptionDeployment: String,
        summaryDeployment: String,
        chatDeployment: String
    ) {
        self.endpoint = endpoint
        self.chatAPIVersion = chatAPIVersion
        self.transcriptionAPIVersion = transcriptionAPIVersion
        self.apiKeyRef = apiKeyRef
        self.transcriptionDeployment = transcriptionDeployment
        self.summaryDeployment = summaryDeployment
        self.chatDeployment = chatDeployment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        let legacyVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        chatAPIVersion = try container.decodeIfPresent(String.self, forKey: .chatAPIVersion)
            ?? legacyVersion
            ?? AzureModelPolicy.defaultChatAPIVersion
        transcriptionAPIVersion = try container.decodeIfPresent(String.self, forKey: .transcriptionAPIVersion)
            ?? legacyVersion
            ?? AzureModelPolicy.defaultTranscriptionAPIVersion
        apiKeyRef = try container.decodeIfPresent(String.self, forKey: .apiKeyRef) ?? "azure-openai-api-key"
        transcriptionDeployment = try container.decodeIfPresent(String.self, forKey: .transcriptionDeployment) ?? AzureModelPolicy.transcriptionDeployment
        summaryDeployment = try container.decodeIfPresent(String.self, forKey: .summaryDeployment) ?? AzureModelPolicy.summaryDeployment
        chatDeployment = try container.decodeIfPresent(String.self, forKey: .chatDeployment) ?? AzureModelPolicy.chatDeployment
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(chatAPIVersion, forKey: .chatAPIVersion)
        try container.encode(transcriptionAPIVersion, forKey: .transcriptionAPIVersion)
        try container.encode(apiKeyRef, forKey: .apiKeyRef)
        try container.encode(transcriptionDeployment, forKey: .transcriptionDeployment)
        try container.encode(summaryDeployment, forKey: .summaryDeployment)
        try container.encode(chatDeployment, forKey: .chatDeployment)
    }

    var apiVersion: String {
        get { chatAPIVersion }
        set {
            chatAPIVersion = newValue
            transcriptionAPIVersion = newValue
        }
    }

    var isConfigured: Bool {
        !endpoint.isEmpty
            && !chatAPIVersion.isEmpty
            && !transcriptionAPIVersion.isEmpty
            && !transcriptionDeployment.isEmpty
            && !summaryDeployment.isEmpty
            && !chatDeployment.isEmpty
    }

    var isTranscriptionConfigured: Bool {
        !endpoint.isEmpty && !transcriptionAPIVersion.isEmpty && !transcriptionDeployment.isEmpty
    }

    var isChatConfigured: Bool {
        !endpoint.isEmpty
            && !chatAPIVersion.isEmpty
            && !summaryDeployment.isEmpty
            && !chatDeployment.isEmpty
    }
}

enum OpenAIModelPolicy {
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let chatModel = "gpt-4.1"
    static let summaryModel = "gpt-4.1"
    static let transcriptionModel = "whisper-1"
}

struct OpenAIConfig: Codable, Equatable {
    var baseURL: String
    var apiKeyRef: String
    var chatModel: String
    var summaryModel: String
    var transcriptionModel: String

    static let empty = OpenAIConfig(
        baseURL: OpenAIModelPolicy.defaultBaseURL,
        apiKeyRef: "openai-api-key",
        chatModel: OpenAIModelPolicy.chatModel,
        summaryModel: OpenAIModelPolicy.summaryModel,
        transcriptionModel: OpenAIModelPolicy.transcriptionModel
    )

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LMStudioConfig: Codable, Equatable {
    var endpoint: String
    var apiKeyRef: String
    var selectedModelIdentifier: String

    static let `default` = LMStudioConfig(
        endpoint: "http://127.0.0.1:1234",
        apiKeyRef: "lmstudio-api-key",
        selectedModelIdentifier: ""
    )

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LocalModelRef: Codable, Equatable {
    var modelId: String
    var manifestURL: String
    var checksumSHA256: String?

    static let defaultParakeet = LocalModelRef(
        modelId: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        manifestURL: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml",
        checksumSHA256: nil
    )
}

struct TranscriptionConfig: Codable, Equatable {
    var providerType: TranscriptionProviderType
    var languageMode: LanguageMode
    var realtimeEnabled: Bool
    var audioCaptureMode: LocalAudioCaptureMode
    var localRealtimeEndpoint: String
    var transcriptionDelayMs: Int
    var localRuntimeLaunchCommand: String?
    var localRuntimeWorkingDirectory: String?
    var azureConfig: AzureConfig?
    var openAIConfig: OpenAIConfig?
    var localModelRef: LocalModelRef?

    init(
        providerType: TranscriptionProviderType,
        languageMode: LanguageMode,
        realtimeEnabled: Bool,
        audioCaptureMode: LocalAudioCaptureMode = .microphoneAndSystem,
        localRealtimeEndpoint: String,
        transcriptionDelayMs: Int,
        localRuntimeLaunchCommand: String?,
        localRuntimeWorkingDirectory: String?,
        azureConfig: AzureConfig?,
        openAIConfig: OpenAIConfig?,
        localModelRef: LocalModelRef?
    ) {
        self.providerType = providerType
        self.languageMode = languageMode
        self.realtimeEnabled = realtimeEnabled
        self.audioCaptureMode = audioCaptureMode
        self.localRealtimeEndpoint = localRealtimeEndpoint
        self.transcriptionDelayMs = transcriptionDelayMs
        self.localRuntimeLaunchCommand = localRuntimeLaunchCommand
        self.localRuntimeWorkingDirectory = localRuntimeWorkingDirectory
        self.azureConfig = azureConfig
        self.openAIConfig = openAIConfig
        self.localModelRef = localModelRef
    }

    private enum CodingKeys: String, CodingKey {
        case providerType
        case languageMode
        case realtimeEnabled
        case audioCaptureMode
        case localRealtimeEndpoint
        case transcriptionDelayMs
        case localRuntimeLaunchCommand
        case localRuntimeWorkingDirectory
        case azureConfig
        case openAIConfig
        case localModelRef
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerType = try container.decode(TranscriptionProviderType.self, forKey: .providerType)
        languageMode = try container.decode(LanguageMode.self, forKey: .languageMode)
        realtimeEnabled = try container.decode(Bool.self, forKey: .realtimeEnabled)
        audioCaptureMode = try container.decodeIfPresent(LocalAudioCaptureMode.self, forKey: .audioCaptureMode) ?? .microphoneAndSystem
        localRealtimeEndpoint = try container.decode(String.self, forKey: .localRealtimeEndpoint)
        transcriptionDelayMs = try container.decode(Int.self, forKey: .transcriptionDelayMs)
        localRuntimeLaunchCommand = try container.decodeIfPresent(String.self, forKey: .localRuntimeLaunchCommand)
        localRuntimeWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .localRuntimeWorkingDirectory)
        azureConfig = try container.decodeIfPresent(AzureConfig.self, forKey: .azureConfig)
        openAIConfig = try container.decodeIfPresent(OpenAIConfig.self, forKey: .openAIConfig)
        localModelRef = try container.decodeIfPresent(LocalModelRef.self, forKey: .localModelRef)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerType, forKey: .providerType)
        try container.encode(languageMode, forKey: .languageMode)
        try container.encode(realtimeEnabled, forKey: .realtimeEnabled)
        try container.encode(audioCaptureMode, forKey: .audioCaptureMode)
        try container.encode(localRealtimeEndpoint, forKey: .localRealtimeEndpoint)
        try container.encode(transcriptionDelayMs, forKey: .transcriptionDelayMs)
        try container.encodeIfPresent(localRuntimeLaunchCommand, forKey: .localRuntimeLaunchCommand)
        try container.encodeIfPresent(localRuntimeWorkingDirectory, forKey: .localRuntimeWorkingDirectory)
        try container.encodeIfPresent(azureConfig, forKey: .azureConfig)
        try container.encodeIfPresent(openAIConfig, forKey: .openAIConfig)
        try container.encodeIfPresent(localModelRef, forKey: .localModelRef)
    }
}

struct AudioChunk: Sendable {
    enum Source: String, Codable, Sendable {
        case microphone
        case systemAudio
    }

    var timestampMs: Int64
    var data: Data
    var sampleRate: Int
    var channels: Int
    var source: Source
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID
    var sessionId: UUID
    var startMs: Int64
    var endMs: Int64
    var text: String
    var confidence: Double
    var sourceProvider: TranscriptionProviderType
    var isFinal: Bool
    var speakerLabel: String? = nil
}

struct Transcript: Codable {
    var sessionId: UUID
    var segments: [TranscriptSegment]

    var plainText: String {
        segments.sorted { $0.startMs < $1.startMs }.map(\ .text).joined(separator: "\n")
    }
}

struct SummaryPrompt: Codable, Equatable {
    var template: String

    private static let legacyDefaultPromptNL = """
Je bent een notule-assistent.
Schrijf in het Nederlands, kort en feitelijk.
Gebruik exact dit format:
1) Kernsamenvatting (max 6 bullets)
2) Besluiten
3) Actiepunten (bullet: taak | eigenaar | deadline of "onbekend")
4) Open vragen
5) Volgende stappen (komende 7 dagen)
Regels:
- Gebruik alleen informatie uit de transcriptie.
- Noem tijdsverwijzingen als [mm:ss-mm:ss] wanneer mogelijk.
- Als iets ontbreekt, zet expliciet "Onbekend".
"""

    private static let legacyDefaultPromptEN = """
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
"""

    private static let legacyDefaultPromptAdaptiveV1 = """
You are a meeting notes assistant.
Write the output in the same dominant language used in the transcript.
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
"""

    static let defaultPromptAdaptive = SummaryPrompt(template: """
<ai_notelist_agent>
  <role>
    You are an AI Notelist Pilot Agent specialized in producing accurate, structured meeting notes from raw transcripts.
  </role>
  <task>
    You will receive a full meeting transcript.
    Your task is to summarize it using a universal, structured format.
  </task>
  <language_rule>
    Detect the dominant language of the transcript by total word frequency.
    Write the entire output strictly in that dominant language.
    Do not use system language, user settings, or personal preference.
    Do not translate unless the transcript itself is multilingual and one language clearly dominates.
  </language_rule>
  <grounding_rules>
    - Use only information that appears explicitly in the transcript.
    - Do not invent decisions, owners, deadlines, numbers, risks, or context.
    - If required information is missing, write "Unknown" in the dominant language.
    - Do not infer intentions that are not clearly stated.
  </grounding_rules>
  <length_rules>
    - Keep the output concise and practical.
    - Executive summary: maximum 6 bullet points.
    - Use short, clear bullets.
    - Avoid long paragraphs.
    - Focus on clarity and usability.
  </length_rules>
  <output_requirements>
    - Output must be written in Markdown.
    - Use exactly the following section order.
    - Do not add extra sections.
    - Do not add explanations before or after the structured output.
    - Do not include timestamps.
    - Do not include examples.
    - Use a single fixed output format.
  </output_requirements>
  <output_format>
## 1. Context
(1-2 short sentences describing the purpose of the meeting)

## 2. Executive Summary
- Bullet 1
- Bullet 2
- Bullet 3
- Bullet 4
- Bullet 5
- Bullet 6

## 3. Decisions
- Clear decision
- If none: Unknown

## 4. Action Items
- Task | Owner | Deadline or Unknown
- Task | Owner | Deadline or Unknown

## 5. Open Questions and Risks
- Question or risk
- If none: Unknown

## 6. Key Details
- Important numbers, dates, commitments
- If none: Unknown

## 7. Next Steps (Next 7 Days)
- Practical next step
- If none: Unknown
  </output_format>
  <quality_checks>
    Before finalizing:
    - Verify that every bullet is grounded in the transcript.
    - Remove any inferred or guessed information.
    - Ensure the entire output is written in the dominant transcript language.
    - Ensure formatting is valid Markdown.
  </quality_checks>
</ai_notelist_agent>
""")

    static var defaultPrompt: SummaryPrompt { defaultPromptAdaptive }

    static var knownDefaultTemplates: Set<String> {
        [
            defaultPromptAdaptive.template,
            legacyDefaultPromptNL,
            legacyDefaultPromptEN,
            legacyDefaultPromptAdaptiveV1
        ]
    }

    func normalizedAgainstKnownDefaults() -> SummaryPrompt {
        if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .defaultPrompt
        }
        if SummaryPrompt.knownDefaultTemplates.contains(template) {
            return .defaultPrompt
        }
        return self
    }
}

struct MeetingSummary: Codable {
    var title: String
    var executiveSummary: String
    var decisions: [String]
    var actionItems: [String]
    var openQuestions: [String]
    var followUps: [String]
    var risks: [String]
    var generatedAt: Date
    var version: Int
}

struct SessionRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var status: SessionStatus
    var transcriptionProvider: TranscriptionProviderType
    var summaryStatus: SummaryStatus
}

struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    var id: UUID
    var threadId: UUID
    var sessionId: UUID
    var role: Role
    var text: String
    var citations: [TranscriptCitation]
    var createdAt: Date
}

struct TranscriptCitation: Codable, Hashable {
    var segmentId: UUID
    var startMs: Int64
    var endMs: Int64
}

struct ChatAnswer: Codable {
    var text: String
    var citations: [TranscriptCitation]
}

enum RetrievalStrategy: String, Codable, CaseIterable {
    case lexicalTopK
}

struct AppSettings: Codable, Equatable {
    var onboardingCompleted: Bool
    var theme: AppTheme
    var appLanguagePreference: AppLanguagePreference
    var cloudProvider: CloudProviderType
    var transcriptionConfig: TranscriptionConfig
    var azureConfig: AzureConfig
    var openAIConfig: OpenAIConfig
    var lmStudioConfig: LMStudioConfig
    var summaryPrompt: SummaryPrompt
    var autoSummarizeAfterStop: Bool
    var encryptionEnabled: Bool
    var transcriptDefaultCollapsed: Bool

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted
        case theme
        case appLanguagePreference
        case cloudProvider
        case transcriptionConfig
        case azureConfig
        case openAIConfig
        case lmStudioConfig
        case summaryPrompt
        case autoSummarizeAfterStop
        case encryptionEnabled
        case transcriptDefaultCollapsed
    }

    static let `default` = AppSettings(
        onboardingCompleted: false,
        theme: .system,
        appLanguagePreference: .system,
        cloudProvider: .azureOpenAI,
        transcriptionConfig: TranscriptionConfig(
            providerType: .localVoxtral,
            languageMode: .auto(preferred: ["nl", "en"]),
            realtimeEnabled: false,
            audioCaptureMode: .microphoneAndSystem,
            localRealtimeEndpoint: "ws://127.0.0.1:8000/v1/realtime",
            transcriptionDelayMs: 480,
            localRuntimeLaunchCommand: "",
            localRuntimeWorkingDirectory: "",
            azureConfig: nil,
            openAIConfig: nil,
            localModelRef: .defaultParakeet
        ),
        azureConfig: .empty,
        openAIConfig: .empty,
        lmStudioConfig: .default,
        summaryPrompt: .defaultPrompt,
        autoSummarizeAfterStop: true,
        encryptionEnabled: false,
        transcriptDefaultCollapsed: false
    )

    init(
        onboardingCompleted: Bool,
        theme: AppTheme,
        appLanguagePreference: AppLanguagePreference,
        cloudProvider: CloudProviderType,
        transcriptionConfig: TranscriptionConfig,
        azureConfig: AzureConfig,
        openAIConfig: OpenAIConfig,
        lmStudioConfig: LMStudioConfig,
        summaryPrompt: SummaryPrompt,
        autoSummarizeAfterStop: Bool,
        encryptionEnabled: Bool,
        transcriptDefaultCollapsed: Bool
    ) {
        self.onboardingCompleted = onboardingCompleted
        self.theme = theme
        self.appLanguagePreference = appLanguagePreference
        self.cloudProvider = cloudProvider
        self.transcriptionConfig = transcriptionConfig
        self.azureConfig = azureConfig
        self.openAIConfig = openAIConfig
        self.lmStudioConfig = lmStudioConfig
        self.summaryPrompt = summaryPrompt
        self.autoSummarizeAfterStop = autoSummarizeAfterStop
        self.encryptionEnabled = encryptionEnabled
        self.transcriptDefaultCollapsed = transcriptDefaultCollapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        appLanguagePreference = try container.decodeIfPresent(AppLanguagePreference.self, forKey: .appLanguagePreference) ?? .system
        cloudProvider = try container.decodeIfPresent(CloudProviderType.self, forKey: .cloudProvider) ?? .azureOpenAI
        transcriptionConfig = try container.decodeIfPresent(TranscriptionConfig.self, forKey: .transcriptionConfig) ?? AppSettings.default.transcriptionConfig
        azureConfig = try container.decodeIfPresent(AzureConfig.self, forKey: .azureConfig) ?? .empty
        openAIConfig = try container.decodeIfPresent(OpenAIConfig.self, forKey: .openAIConfig) ?? .empty
        lmStudioConfig = try container.decodeIfPresent(LMStudioConfig.self, forKey: .lmStudioConfig) ?? .default
        summaryPrompt = try container.decodeIfPresent(SummaryPrompt.self, forKey: .summaryPrompt) ?? .defaultPrompt
        autoSummarizeAfterStop = try container.decodeIfPresent(Bool.self, forKey: .autoSummarizeAfterStop) ?? true
        encryptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .encryptionEnabled) ?? false
        transcriptDefaultCollapsed = try container.decodeIfPresent(Bool.self, forKey: .transcriptDefaultCollapsed) ?? false
    }
}

struct ModelInstallationState: Codable {
    var modelId: String
    var status: ModelInstallStatus
    var progress: Double
    var localPath: String?
    var lastError: String?
}
