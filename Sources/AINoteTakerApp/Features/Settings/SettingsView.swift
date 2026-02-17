import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case ai = "AI"
        case advanced = "Advanced"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab = .general
    @State private var draft: AppSettings = .default
    @State private var azureApiKey: String = ""
    @State private var openAIApiKey: String = ""
    @State private var lmStudioApiKey: String = ""
    @State private var azureParseFeedbackKey: String?
    @State private var azureParseFeedbackIsWarning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))

            Picker("Tab", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .ai:
                    aiTab
                case .advanced:
                    advancedTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    Task {
                        await viewModel.saveSettings(
                            draft,
                            azureApiKey: azureApiKey.isEmpty ? nil : azureApiKey,
                            openAIApiKey: openAIApiKey.isEmpty ? nil : openAIApiKey,
                            lmStudioApiKey: lmStudioApiKey.isEmpty ? nil : lmStudioApiKey
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear {
            draft = viewModel.settings
            Task {
                await viewModel.refreshLMStudioRuntimeStatus()
                if draft.lmStudioConfig.selectedModelIdentifier.isEmpty,
                   let first = viewModel.lmStudioLoadedModels.first {
                    draft.lmStudioConfig.selectedModelIdentifier = first.identifier
                }
            }
        }
        .onChange(of: draft.transcriptionConfig.providerType) { _, newValue in
            switch newValue {
            case .azure:
                draft.cloudProvider = .azureOpenAI
            case .openAI:
                draft.cloudProvider = .openAI
            case .localVoxtral:
                break
            }
        }
        .onChange(of: draft.cloudProvider) { _, newValue in
            switch newValue {
            case .azureOpenAI where draft.transcriptionConfig.providerType == .openAI:
                draft.transcriptionConfig.providerType = .azure
            case .openAI where draft.transcriptionConfig.providerType == .azure:
                draft.transcriptionConfig.providerType = .openAI
            case .lmStudio:
                break
            default:
                break
            }
        }
        .onChange(of: selectedTab) { _, value in
            if value == .ai {
                Task {
                    await viewModel.refreshLMStudioRuntimeStatus()
                    if draft.lmStudioConfig.selectedModelIdentifier.isEmpty,
                       let first = viewModel.lmStudioLoadedModels.first {
                        draft.lmStudioConfig.selectedModelIdentifier = first.identifier
                    }
                }
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $draft.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
                Picker("App language", selection: $draft.appLanguagePreference) {
                    Text("System").tag(AppLanguagePreference.system)
                    Text("Nederlands").tag(AppLanguagePreference.dutch)
                    Text("English").tag(AppLanguagePreference.english)
                }
            }

            Section("Transcript") {
                Toggle("Collapse full transcript by default", isOn: $draft.transcriptDefaultCollapsed)
            }

            Section("Transcription") {
                Picker("Provider", selection: $draft.transcriptionConfig.providerType) {
                    Text("FluidAudio (Parakeet v3)").tag(TranscriptionProviderType.localVoxtral)
                    Text("Azure OpenAI").tag(TranscriptionProviderType.azure)
                    Text("OpenAI").tag(TranscriptionProviderType.openAI)
                }

                Picker("Audio capture", selection: $draft.transcriptionConfig.audioCaptureMode) {
                    Text("Microfoon alleen").tag(LocalAudioCaptureMode.microphoneOnly)
                    Text("Microfoon + systeemaudio").tag(LocalAudioCaptureMode.microphoneAndSystem)
                }
                Text("Kies microfoon alleen voor face-to-face gesprekken. Kies microfoon + systeemaudio voor online meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto summarize after stop", isOn: $draft.autoSummarizeAfterStop)
            }

            Section("Lokale modelvoorbereiding") {
                HStack {
                    Text("Local FluidAudio")
                    Spacer()
                    Text(viewModel.localRuntimeStatusText)
                        .foregroundStyle(viewModel.isLocalRuntimeReachable ? .green : .secondary)
                }
                Text("Modeldownload en initialisatie starten on-demand bij de eerste lokale opname.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Run onboarding again") {
                    Task {
                        await viewModel.resetOnboardingFlow()
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var aiTab: some View {
        Form {
            Section("Cloud provider for summary + chat") {
                Picker("Provider", selection: $draft.cloudProvider) {
                    Text("Azure OpenAI").tag(CloudProviderType.azureOpenAI)
                    Text("OpenAI").tag(CloudProviderType.openAI)
                    Text("LM Studio (Local)").tag(CloudProviderType.lmStudio)
                }
            }

            if draft.cloudProvider == .azureOpenAI || draft.transcriptionConfig.providerType == .azure {
                Section("Azure OpenAI") {
                    TextField("Endpoint", text: Binding(
                        get: { draft.azureConfig.endpoint },
                        set: { value in
                            draft.azureConfig.endpoint = value
                            parseAndApplyAzureURLsIfNeeded(from: value)
                        }
                    ))
                    TextField("Chat API version", text: $draft.azureConfig.chatAPIVersion)
                    TextField("Transcription API version", text: $draft.azureConfig.transcriptionAPIVersion)
                    TextField("Chat deployment", text: $draft.azureConfig.chatDeployment)
                    TextField("Summary deployment", text: $draft.azureConfig.summaryDeployment)
                    TextField("Transcription deployment", text: $draft.azureConfig.transcriptionDeployment)
                    SecureField("API key (optional update)", text: $azureApiKey)
                    Text("Bij de eerste keychain prompt: kies 'Always Allow' zodat je niet telkens opnieuw je wachtwoord hoeft in te vullen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let azureParseFeedbackKey {
                        Text(LocalizedStringKey(azureParseFeedbackKey))
                            .font(.caption)
                            .foregroundStyle(azureParseFeedbackIsWarning ? .orange : .secondary)
                    }
                }
            }

            if draft.cloudProvider == .openAI || draft.transcriptionConfig.providerType == .openAI {
                Section("OpenAI") {
                    TextField("Base URL", text: $draft.openAIConfig.baseURL)
                    TextField("Chat model", text: $draft.openAIConfig.chatModel)
                    TextField("Summary model", text: $draft.openAIConfig.summaryModel)
                    TextField("Transcription model", text: $draft.openAIConfig.transcriptionModel)
                    SecureField("API key (optional update)", text: $openAIApiKey)
                }
            }

            if draft.cloudProvider == .lmStudio {
                Section("LM Studio (Local)") {
                    TextField("Endpoint", text: $draft.lmStudioConfig.endpoint)
                    SecureField("API key (optional update)", text: $lmStudioApiKey)

                    if viewModel.lmStudioLoadedModels.isEmpty {
                        Text("No loaded models detected. Load a model in LM Studio first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Loaded model", selection: $draft.lmStudioConfig.selectedModelIdentifier) {
                            ForEach(viewModel.lmStudioLoadedModels) { model in
                                Text(model.displayName).tag(model.identifier)
                            }
                        }
                    }

                    HStack {
                        Text(viewModel.lmStudioStatusText)
                            .foregroundStyle(viewModel.lmStudioServerReachable ? .green : .secondary)
                        Spacer()
                        if viewModel.isLMStudioChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if !viewModel.lmStudioStatusDetail.isEmpty {
                        Text(viewModel.lmStudioStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Refresh status") {
                            Task { await viewModel.refreshLMStudioRuntimeStatus() }
                        }
                        .buttonStyle(.bordered)

                        if viewModel.lmStudioInstalled {
                            Button("Open LM Studio") {
                                viewModel.openLMStudioApp()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Install LM Studio") {
                                viewModel.openLMStudioDownloadPage()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text("Use LM Studio for local chat + summary. Transcription stays on FluidAudio/OpenAI/Azure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Security") {
                Toggle("Encryption enabled", isOn: $draft.encryptionEnabled)
                if draft.encryptionEnabled != viewModel.settings.encryptionEnabled {
                    Text("Wijziging wordt toegepast na herstart van de app.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Storage: \(AppPaths.appSupportDirectory.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Section("Summary prompt") {
                TextEditor(text: Binding(
                    get: { draft.summaryPrompt.template },
                    set: { draft.summaryPrompt = SummaryPrompt(template: $0) }
                ))
                .frame(height: 180)
            }
        }
    }

    private func parseAndApplyAzureURLsIfNeeded(from input: String) {
        let lower = input.lowercased()
        let shouldParse = lower.contains("/openai/deployments/")
            || lower.contains("api-version=")
            || input.contains(" ")
            || input.contains("\n")
        guard shouldParse else {
            azureParseFeedbackKey = nil
            return
        }

        let result = AzureEndpointPasteParser.parse(input)
        guard result.didParseAny else {
            azureParseFeedbackKey = "azure.parse.feedback.no_match"
            azureParseFeedbackIsWarning = true
            return
        }

        if let endpoint = result.endpoint {
            draft.azureConfig.endpoint = endpoint
        }
        if let deployment = result.chatDeployment, !deployment.isEmpty {
            draft.azureConfig.chatDeployment = deployment
            draft.azureConfig.summaryDeployment = deployment
        }
        if let deployment = result.transcriptionDeployment, !deployment.isEmpty {
            draft.azureConfig.transcriptionDeployment = deployment
        }
        if let version = result.chatAPIVersion, !version.isEmpty {
            draft.azureConfig.chatAPIVersion = version
        }
        if let version = result.transcriptionAPIVersion, !version.isEmpty {
            draft.azureConfig.transcriptionAPIVersion = version
        }

        if result.usedTranslationsRoute {
            azureParseFeedbackKey = "azure.parse.feedback.success_with_translation_warning"
            azureParseFeedbackIsWarning = true
            return
        }
        if !result.warnings.isEmpty {
            azureParseFeedbackKey = result.warnings[0]
            azureParseFeedbackIsWarning = true
            return
        }

        azureParseFeedbackKey = "azure.parse.feedback.success"
        azureParseFeedbackIsWarning = false
    }
}
