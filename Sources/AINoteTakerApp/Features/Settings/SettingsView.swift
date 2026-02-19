import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case ai = "AI"
        case advanced = "Advanced"

        var id: String { rawValue }

        var localizedLabel: String {
            switch self {
            case .general:
                return L10n.tr("ui.settings.tab.general")
            case .ai:
                return L10n.tr("ui.settings.tab.ai")
            case .advanced:
                return L10n.tr("ui.settings.tab.advanced")
            }
        }
    }

    @ObservedObject var viewModel: AppViewModel
    @EnvironmentObject private var updateService: GitHubUpdateService
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
            Text(L10n.tr("ui.settings.title"))
                .font(.largeTitle.weight(.semibold))

            Picker(L10n.tr("ui.settings.tab_label"), selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.localizedLabel).tag(tab)
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
                Button(L10n.tr("ui.common.cancel")) { dismiss() }
                Spacer()
                Button(L10n.tr("ui.common.save")) {
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
            Section(L10n.tr("ui.settings.section.appearance")) {
                Picker(L10n.tr("ui.settings.theme"), selection: $draft.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.localizedLabel).tag(theme)
                    }
                }
                Picker(L10n.tr("ui.settings.app_language"), selection: $draft.appLanguagePreference) {
                    Text(AppLanguagePreference.system.localizedLabel).tag(AppLanguagePreference.system)
                    Text(AppLanguagePreference.dutch.localizedLabel).tag(AppLanguagePreference.dutch)
                    Text(AppLanguagePreference.english.localizedLabel).tag(AppLanguagePreference.english)
                }
            }

            Section(L10n.tr("ui.settings.section.transcript")) {
                Toggle(L10n.tr("ui.settings.collapse_transcript_by_default"), isOn: $draft.transcriptDefaultCollapsed)
            }

            Section(L10n.tr("ui.settings.section.transcription")) {
                Picker(L10n.tr("ui.common.provider"), selection: $draft.transcriptionConfig.providerType) {
                    Text(TranscriptionProviderType.localVoxtral.localizedLabel).tag(TranscriptionProviderType.localVoxtral)
                    Text(TranscriptionProviderType.azure.localizedLabel).tag(TranscriptionProviderType.azure)
                    Text(TranscriptionProviderType.openAI.localizedLabel).tag(TranscriptionProviderType.openAI)
                }

                Picker(L10n.tr("ui.settings.audio_capture"), selection: $draft.transcriptionConfig.audioCaptureMode) {
                    Text(LocalAudioCaptureMode.microphoneOnly.localizedLabel).tag(LocalAudioCaptureMode.microphoneOnly)
                    Text(LocalAudioCaptureMode.microphoneAndSystem.localizedLabel).tag(LocalAudioCaptureMode.microphoneAndSystem)
                }
                .disabled(!viewModel.canChangeAudioCaptureMode)
                Text(L10n.tr("ui.settings.audio_capture_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.canChangeAudioCaptureMode {
                    Text(L10n.tr("ui.settings.audio_capture_locked_recording"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle(L10n.tr("ui.settings.auto_summarize_after_stop"), isOn: $draft.autoSummarizeAfterStop)
            }

            Section(L10n.tr("ui.settings.section.local_model_preparation")) {
                HStack {
                    Text(L10n.tr("ui.settings.local_fluidaudio"))
                    Spacer()
                    Text(viewModel.localRuntimeStatusText)
                        .foregroundStyle(viewModel.isLocalRuntimeReachable ? .green : .secondary)
                }
                Text(L10n.tr("ui.settings.local_model_preparation_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.tr("ui.settings.run_onboarding_again")) {
                    Task {
                        await viewModel.resetOnboardingFlow()
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
            }

            Section(L10n.tr("ui.settings.section.updates")) {
                HStack {
                    Text(L10n.tr("ui.settings.updates.current_version"))
                    Spacer()
                    Text(updateService.currentVersion)
                        .foregroundStyle(.secondary)
                }

                if let latest = updateService.latestKnownVersion {
                    HStack {
                        Text(L10n.tr("ui.settings.updates.latest_version"))
                        Spacer()
                        Text(latest)
                            .foregroundStyle(.secondary)
                    }
                }

                if let status = updateService.lastStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(updateService.lastStatusIsError ? .orange : .secondary)
                }

                HStack {
                    Button(L10n.tr("ui.updates.menu.check_for_updates")) {
                        Task {
                            await updateService.checkForUpdates(userInitiated: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updateService.isChecking)

                    Button(L10n.tr("ui.settings.updates.open_releases")) {
                        updateService.openLatestReleasePage()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var aiTab: some View {
        Form {
            Section(L10n.tr("ui.settings.section.cloud_provider_for_summary_chat")) {
                Picker(L10n.tr("ui.common.provider"), selection: $draft.cloudProvider) {
                    Text(CloudProviderType.azureOpenAI.localizedLabel).tag(CloudProviderType.azureOpenAI)
                    Text(CloudProviderType.openAI.localizedLabel).tag(CloudProviderType.openAI)
                    Text(CloudProviderType.lmStudio.localizedLabel).tag(CloudProviderType.lmStudio)
                }
            }

            if draft.cloudProvider == .azureOpenAI || draft.transcriptionConfig.providerType == .azure {
                Section(L10n.tr("ui.common.provider.azure_openai")) {
                    TextField(L10n.tr("ui.settings.azure.endpoint"), text: Binding(
                        get: { draft.azureConfig.endpoint },
                        set: { value in
                            draft.azureConfig.endpoint = value
                            parseAndApplyAzureURLsIfNeeded(from: value)
                        }
                    ))
                    TextField(L10n.tr("ui.settings.azure.chat_api_version"), text: $draft.azureConfig.chatAPIVersion)
                    TextField(L10n.tr("ui.settings.azure.transcription_api_version"), text: $draft.azureConfig.transcriptionAPIVersion)
                    TextField(L10n.tr("ui.settings.azure.chat_deployment"), text: $draft.azureConfig.chatDeployment)
                    TextField(L10n.tr("ui.settings.azure.summary_deployment"), text: $draft.azureConfig.summaryDeployment)
                    TextField(L10n.tr("ui.settings.azure.transcription_deployment"), text: $draft.azureConfig.transcriptionDeployment)
                    SecureField(L10n.tr("ui.settings.api_key_optional_update"), text: $azureApiKey)
                    Text(L10n.tr("ui.settings.keychain_prompt_hint"))
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
                Section(L10n.tr("ui.common.provider.openai")) {
                    TextField(L10n.tr("ui.settings.openai.base_url"), text: $draft.openAIConfig.baseURL)
                    TextField(L10n.tr("ui.settings.openai.chat_model"), text: $draft.openAIConfig.chatModel)
                    TextField(L10n.tr("ui.settings.openai.summary_model"), text: $draft.openAIConfig.summaryModel)
                    TextField(L10n.tr("ui.settings.openai.transcription_model"), text: $draft.openAIConfig.transcriptionModel)
                    SecureField(L10n.tr("ui.settings.api_key_optional_update"), text: $openAIApiKey)
                }
            }

            if draft.cloudProvider == .lmStudio {
                Section(L10n.tr("ui.common.provider.lmstudio_local")) {
                    TextField(L10n.tr("ui.settings.lmstudio.endpoint"), text: $draft.lmStudioConfig.endpoint)
                    SecureField(L10n.tr("ui.settings.api_key_optional_update"), text: $lmStudioApiKey)

                    if viewModel.lmStudioLoadedModels.isEmpty {
                        Text(L10n.tr("ui.settings.lmstudio.no_loaded_models"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.tr("ui.settings.lmstudio.loaded_model"), selection: $draft.lmStudioConfig.selectedModelIdentifier) {
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
                        Button(L10n.tr("ui.settings.lmstudio.refresh_status")) {
                            Task { await viewModel.refreshLMStudioRuntimeStatus() }
                        }
                        .buttonStyle(.bordered)

                        if viewModel.lmStudioInstalled {
                            Button(L10n.tr("ui.settings.lmstudio.open")) {
                                viewModel.openLMStudioApp()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(L10n.tr("ui.settings.lmstudio.install")) {
                                viewModel.openLMStudioDownloadPage()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text(L10n.tr("ui.settings.lmstudio.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.tr("ui.settings.section.security")) {
                Toggle(L10n.tr("ui.settings.security.encryption_enabled"), isOn: $draft.encryptionEnabled)
                if draft.encryptionEnabled != viewModel.settings.encryptionEnabled {
                    Text(L10n.tr("ui.settings.security.change_after_restart"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L10n.tr("ui.settings.security.storage_path", AppPaths.appSupportDirectory.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Section(L10n.tr("ui.settings.section.summary_prompt")) {
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
