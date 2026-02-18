import SwiftUI
import AppKit

struct OnboardingWizardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: AppViewModel

    @State private var step: Int = 0
    @State private var draftSettings: AppSettings = .default
    @State private var azureApiKeyInput: String = ""
    @State private var openAIApiKeyInput: String = ""
    @State private var lmStudioApiKeyInput: String = ""
    @State private var azureParseFeedbackKey: String?
    @State private var azureParseFeedbackIsWarning: Bool = false

    @State private var micPermission: PermissionState = Permissions.microphoneState()
    @State private var screenPermission: PermissionState = Permissions.screenCaptureState()

    private let caps = DeviceGuard.inspect()
    private var bundleIdentifierText: String {
        Bundle.main.bundleIdentifier ?? L10n.tr("ui.onboarding.bundle_id_missing")
    }
    private var runningAsAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var requiresScreenPermission: Bool {
        draftSettings.transcriptionConfig.audioCaptureMode == .microphoneAndSystem
    }

    private var permissionsSatisfied: Bool {
        let micOk = micPermission == .granted
        let screenOk = !requiresScreenPermission || screenPermission == .granted
        return micOk && screenOk
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("ui.onboarding.title"))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text(L10n.tr("ui.onboarding.step_of_total", step + 1, 3))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            currentStepView
                .liquidGlassCard()

            HStack(spacing: 10) {
                Button(L10n.tr("ui.common.back")) {
                    step = max(0, step - 1)
                }
                .disabled(step == 0)

                Spacer()

                if step < 2 {
                    Button(L10n.tr("ui.common.next")) {
                        guard canContinue else { return }
                        step = min(2, step + 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                } else {
                    Button(L10n.tr("ui.onboarding.start_app")) {
                        guard canContinue else { return }
                        Task {
                            await viewModel.completeOnboarding(
                                with: draftSettings,
                                azureApiKey: azureApiKeyInput.isEmpty ? nil : azureApiKeyInput,
                                openAIApiKey: openAIApiKeyInput.isEmpty ? nil : openAIApiKeyInput,
                                lmStudioApiKey: lmStudioApiKeyInput.isEmpty ? nil : lmStudioApiKeyInput
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Group {
                if colorScheme == .dark {
                    Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
                } else {
                    Color.white
                }
            }
            .ignoresSafeArea()
        )
        .onAppear {
            draftSettings = viewModel.settings
            refreshPermissionStates()
            Task {
                await viewModel.refreshLMStudioRuntimeStatus()
                if viewModel.lmStudioInstalled == false && draftSettings.cloudProvider == .lmStudio {
                    draftSettings.cloudProvider = .azureOpenAI
                }
                if draftSettings.lmStudioConfig.selectedModelIdentifier.isEmpty,
                   let first = viewModel.lmStudioLoadedModels.first {
                    draftSettings.lmStudioConfig.selectedModelIdentifier = first.identifier
                }
            }
        }
        .onChange(of: draftSettings.transcriptionConfig.providerType) { _, value in
            switch value {
            case .azure:
                draftSettings.cloudProvider = .azureOpenAI
            case .openAI:
                draftSettings.cloudProvider = .openAI
            case .localVoxtral:
                break
            }
        }
        .onChange(of: draftSettings.cloudProvider) { _, value in
            switch value {
            case .azureOpenAI where draftSettings.transcriptionConfig.providerType == .openAI:
                draftSettings.transcriptionConfig.providerType = .azure
            case .openAI where draftSettings.transcriptionConfig.providerType == .azure:
                draftSettings.transcriptionConfig.providerType = .openAI
            case .lmStudio:
                break
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            Task { await viewModel.refreshLMStudioRuntimeStatus() }
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch step {
        case 0:
            requirementsStep
        case 1:
            transcriptionStep
        default:
            aiStep
        }
    }

    private var canContinue: Bool {
        if step == 0 {
            return caps.meetsMinimumRequirements && permissionsSatisfied
        }
        if step == 2 {
            return permissionsSatisfied
        }
        return true
    }

    private var requirementsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("ui.onboarding.system_permissions"))
                .font(.title2.weight(.semibold))

            Label(
                caps.isAppleSilicon
                    ? L10n.tr("ui.onboarding.apple_silicon")
                    : L10n.tr("ui.onboarding.no_apple_silicon"),
                systemImage: caps.isAppleSilicon ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
                .foregroundStyle(caps.isAppleSilicon ? .green : .red)

            Label(
                L10n.tr("ui.onboarding.ram_value", caps.physicalMemoryGB),
                systemImage: caps.physicalMemoryGB >= 16 ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
                .foregroundStyle(caps.physicalMemoryGB >= 16 ? .green : .red)

            Divider()

            HStack {
                Text(L10n.tr("ui.onboarding.microphone"))
                Spacer()
                Text(micPermission.localizedLabel)
                    .foregroundStyle(micPermission == .granted ? .green : .secondary)
                Button(micPermission == .denied ? L10n.tr("ui.common.open_settings") : L10n.tr("ui.common.allow")) {
                    if micPermission == .denied {
                        Permissions.openMicrophoneSettings()
                    } else {
                        Task {
                            _ = await Permissions.requestMicrophone()
                            refreshPermissionStates()
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Text(L10n.tr("ui.onboarding.screen_recording"))
                Spacer()
                Text(screenPermission.localizedLabel)
                    .foregroundStyle(screenPermission == .granted ? .green : .secondary)
                Button(screenCaptureActionLabel) {
                    switch screenPermission {
                    case .granted:
                        break
                    case .notDetermined:
                        _ = Permissions.requestScreenCapture()
                        refreshPermissionStates()
                    case .denied:
                        Permissions.openScreenCaptureSettings()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(screenPermission == .granted)
            }

            if !caps.meetsMinimumRequirements {
                Text(L10n.tr("ui.onboarding.requirements_not_met"))
                    .foregroundStyle(.red)
            }
            if !permissionsSatisfied {
                Text(requiresScreenPermission
                     ? L10n.tr("ui.onboarding.allow_mic_and_screen")
                     : L10n.tr("ui.onboarding.allow_mic_only"))
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text(L10n.tr("ui.onboarding.bundle_id"))
                Spacer()
                Text(bundleIdentifierText)
                    .font(.caption)
                    .foregroundStyle(bundleIdentifierText == L10n.tr("ui.onboarding.bundle_id_missing") ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !runningAsAppBundle {
                Text(L10n.tr("ui.onboarding.not_app_bundle_warning"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("ui.onboarding.transcription"))
                .font(.title2.weight(.semibold))

            Picker(L10n.tr("ui.onboarding.engine"), selection: $draftSettings.transcriptionConfig.providerType) {
                Text(L10n.tr("ui.onboarding.engine.local_fluidaudio")).tag(TranscriptionProviderType.localVoxtral)
                Text(L10n.tr("ui.onboarding.engine.cloud_azure_transcription")).tag(TranscriptionProviderType.azure)
                Text(L10n.tr("ui.onboarding.engine.cloud_openai_transcription")).tag(TranscriptionProviderType.openAI)
            }
            .pickerStyle(.radioGroup)

            Toggle(L10n.tr("ui.settings.auto_summarize_after_stop"), isOn: $draftSettings.autoSummarizeAfterStop)
            Toggle(L10n.tr("ui.settings.collapse_transcript_by_default"), isOn: $draftSettings.transcriptDefaultCollapsed)

            Text(L10n.tr("ui.onboarding.local_model_prep_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("ui.onboarding.ai_optional"))
                .font(.title2.weight(.semibold))

            Picker(L10n.tr("ui.onboarding.cloud_provider_for_summary_chat"), selection: $draftSettings.cloudProvider) {
                Text(CloudProviderType.azureOpenAI.localizedLabel).tag(CloudProviderType.azureOpenAI)
                Text(CloudProviderType.openAI.localizedLabel).tag(CloudProviderType.openAI)
                if viewModel.lmStudioInstalled {
                    Text(CloudProviderType.lmStudio.localizedLabel).tag(CloudProviderType.lmStudio)
                }
            }
            .pickerStyle(.segmented)

            if draftSettings.cloudProvider == .azureOpenAI || draftSettings.transcriptionConfig.providerType == .azure {
                Text(L10n.tr("ui.onboarding.azure.configure_hint"))
                    .foregroundStyle(.secondary)

                TextField(L10n.tr("ui.onboarding.azure.endpoint"), text: Binding(
                    get: { draftSettings.azureConfig.endpoint },
                    set: { value in
                        draftSettings.azureConfig.endpoint = value
                        parseAndApplyAzureURLsIfNeeded(from: value)
                    }
                ))
                TextField(L10n.tr("ui.settings.azure.chat_api_version"), text: $draftSettings.azureConfig.chatAPIVersion)
                TextField(L10n.tr("ui.settings.azure.transcription_api_version"), text: $draftSettings.azureConfig.transcriptionAPIVersion)
                TextField(L10n.tr("ui.settings.azure.chat_deployment"), text: $draftSettings.azureConfig.chatDeployment)
                TextField(L10n.tr("ui.settings.azure.summary_deployment"), text: $draftSettings.azureConfig.summaryDeployment)
                TextField(L10n.tr("ui.settings.azure.transcription_deployment"), text: $draftSettings.azureConfig.transcriptionDeployment)
                SecureField(L10n.tr("ui.settings.api_key"), text: $azureApiKeyInput)
                Text(L10n.tr("ui.settings.keychain_prompt_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let azureParseFeedbackKey {
                    Text(LocalizedStringKey(azureParseFeedbackKey))
                        .font(.caption)
                        .foregroundStyle(azureParseFeedbackIsWarning ? .orange : .secondary)
                }
            }

            if draftSettings.cloudProvider == .openAI || draftSettings.transcriptionConfig.providerType == .openAI {
                Text(L10n.tr("ui.onboarding.openai.configure_hint"))
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("ui.settings.openai.base_url"), text: $draftSettings.openAIConfig.baseURL)
                TextField(L10n.tr("ui.settings.openai.chat_model"), text: $draftSettings.openAIConfig.chatModel)
                TextField(L10n.tr("ui.settings.openai.summary_model"), text: $draftSettings.openAIConfig.summaryModel)
                TextField(L10n.tr("ui.settings.openai.transcription_model"), text: $draftSettings.openAIConfig.transcriptionModel)
                SecureField(L10n.tr("ui.settings.api_key"), text: $openAIApiKeyInput)
            }

            if draftSettings.cloudProvider == .lmStudio {
                Text(L10n.tr("ui.onboarding.lmstudio.configure_hint"))
                    .foregroundStyle(.secondary)

                TextField(L10n.tr("ui.settings.lmstudio.endpoint"), text: $draftSettings.lmStudioConfig.endpoint)
                SecureField(L10n.tr("ui.settings.api_key_optional"), text: $lmStudioApiKeyInput)

                if viewModel.lmStudioLoadedModels.isEmpty {
                    Text(L10n.tr("ui.onboarding.lmstudio.load_model_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(L10n.tr("ui.settings.lmstudio.loaded_model"), selection: $draftSettings.lmStudioConfig.selectedModelIdentifier) {
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
                    Button(L10n.tr("ui.common.refresh")) {
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

                Text(L10n.tr("ui.onboarding.ram_guidance"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(L10n.tr("ui.onboarding.lmstudio_docs"), destination: URL(string: "https://lmstudio.ai/docs/developer/rest")!)
                    .font(.caption)
            }

            Text(L10n.tr("ui.onboarding.advanced_settings_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshPermissionStates() {
        micPermission = Permissions.microphoneState()
        screenPermission = Permissions.screenCaptureState()
        Task { @MainActor in
            screenPermission = await Permissions.refreshScreenCaptureState()
        }
    }

    private var screenCaptureActionLabel: String {
        switch screenPermission {
        case .granted:
            return L10n.tr("ui.onboarding.screen_recording.active")
        case .notDetermined:
            return L10n.tr("ui.common.allow")
        case .denied:
            return L10n.tr("ui.common.open_settings")
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
            draftSettings.azureConfig.endpoint = endpoint
        }
        if let deployment = result.chatDeployment, !deployment.isEmpty {
            draftSettings.azureConfig.chatDeployment = deployment
            draftSettings.azureConfig.summaryDeployment = deployment
        }
        if let deployment = result.transcriptionDeployment, !deployment.isEmpty {
            draftSettings.azureConfig.transcriptionDeployment = deployment
        }
        if let version = result.chatAPIVersion, !version.isEmpty {
            draftSettings.azureConfig.chatAPIVersion = version
        }
        if let version = result.transcriptionAPIVersion, !version.isEmpty {
            draftSettings.azureConfig.transcriptionAPIVersion = version
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
