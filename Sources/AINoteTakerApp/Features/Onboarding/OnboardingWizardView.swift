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
        Bundle.main.bundleIdentifier ?? "Missing"
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
                Text("MinuteWave Setup")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Stap \(step + 1) van 3")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            currentStepView
                .liquidGlassCard()

            HStack(spacing: 10) {
                Button("Terug") {
                    step = max(0, step - 1)
                }
                .disabled(step == 0)

                Spacer()

                if step < 2 {
                    Button("Volgende") {
                        guard canContinue else { return }
                        step = min(2, step + 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                } else {
                    Button("Start app") {
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
            Text("Systeem & permissies")
                .font(.title2.weight(.semibold))

            Label(caps.isAppleSilicon ? "Apple Silicon" : "Geen Apple Silicon", systemImage: caps.isAppleSilicon ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(caps.isAppleSilicon ? .green : .red)

            Label("\(caps.physicalMemoryGB) GB RAM", systemImage: caps.physicalMemoryGB >= 16 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(caps.physicalMemoryGB >= 16 ? .green : .red)

            Divider()

            HStack {
                Text("Microfoon")
                Spacer()
                Text(micPermission.rawValue)
                    .foregroundStyle(micPermission == .granted ? .green : .secondary)
                Button(micPermission == .denied ? "Open settings" : "Toestaan") {
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
                Text("Screen Recording (system audio)")
                Spacer()
                Text(screenPermission.rawValue)
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
                Text("Deze app vereist Apple Silicon en minimaal 16GB RAM.")
                    .foregroundStyle(.red)
            }
            if !permissionsSatisfied {
                Text(requiresScreenPermission
                     ? "Sta microfoon en Screen Recording toe voordat je verdergaat."
                     : "Sta microfoon toe voordat je verdergaat.")
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text("Bundle ID")
                Spacer()
                Text(bundleIdentifierText)
                    .font(.caption)
                    .foregroundStyle(bundleIdentifierText == "Missing" ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !runningAsAppBundle {
                Text("Je draait nu niet als echte .app-bundle. Voor betrouwbare macOS permissieprompts: bouw en start via scripts/build_dev_app_bundle.sh.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcriptie")
                .font(.title2.weight(.semibold))

            Picker("Engine", selection: $draftSettings.transcriptionConfig.providerType) {
                Text("Lokaal (FluidAudio Parakeet v3)").tag(TranscriptionProviderType.localVoxtral)
                Text("Cloud (Azure transcription)").tag(TranscriptionProviderType.azure)
                Text("Cloud (OpenAI transcription)").tag(TranscriptionProviderType.openAI)
            }
            .pickerStyle(.radioGroup)

            Toggle("Auto samenvatten na stop", isOn: $draftSettings.autoSummarizeAfterStop)
            Toggle("Ingeklapte transcriptie als standaard", isOn: $draftSettings.transcriptDefaultCollapsed)

            Text("Bij lokaal gebruik worden modellen voorbereid bij de eerste opnamepoging.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI (optioneel)")
                .font(.title2.weight(.semibold))

            Picker("Cloud provider voor samenvatting + chat", selection: $draftSettings.cloudProvider) {
                Text("Azure OpenAI").tag(CloudProviderType.azureOpenAI)
                Text("OpenAI").tag(CloudProviderType.openAI)
                if viewModel.lmStudioInstalled {
                    Text("LM Studio (Local)").tag(CloudProviderType.lmStudio)
                }
            }
            .pickerStyle(.segmented)

            if draftSettings.cloudProvider == .azureOpenAI || draftSettings.transcriptionConfig.providerType == .azure {
                Text("Configureer Azure OpenAI voor samenvatten en chat met transcript.")
                    .foregroundStyle(.secondary)

                TextField("Endpoint (https://...openai.azure.com)", text: Binding(
                    get: { draftSettings.azureConfig.endpoint },
                    set: { value in
                        draftSettings.azureConfig.endpoint = value
                        parseAndApplyAzureURLsIfNeeded(from: value)
                    }
                ))
                TextField("Chat API version", text: $draftSettings.azureConfig.chatAPIVersion)
                TextField("Transcription API version", text: $draftSettings.azureConfig.transcriptionAPIVersion)
                TextField("Chat deployment", text: $draftSettings.azureConfig.chatDeployment)
                TextField("Summary deployment", text: $draftSettings.azureConfig.summaryDeployment)
                TextField("Transcription deployment", text: $draftSettings.azureConfig.transcriptionDeployment)
                SecureField("API key", text: $azureApiKeyInput)
                Text("Bij de eerste keychain prompt: kies 'Always Allow' zodat je niet telkens opnieuw je wachtwoord hoeft in te vullen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let azureParseFeedbackKey {
                    Text(LocalizedStringKey(azureParseFeedbackKey))
                        .font(.caption)
                        .foregroundStyle(azureParseFeedbackIsWarning ? .orange : .secondary)
                }
            }

            if draftSettings.cloudProvider == .openAI || draftSettings.transcriptionConfig.providerType == .openAI {
                Text("Configureer OpenAI API voor samenvatten, chat en transcriptie.")
                    .foregroundStyle(.secondary)
                TextField("Base URL", text: $draftSettings.openAIConfig.baseURL)
                TextField("Chat model", text: $draftSettings.openAIConfig.chatModel)
                TextField("Summary model", text: $draftSettings.openAIConfig.summaryModel)
                TextField("Transcription model", text: $draftSettings.openAIConfig.transcriptionModel)
                SecureField("API key", text: $openAIApiKeyInput)
            }

            if draftSettings.cloudProvider == .lmStudio {
                Text("Gebruik LM Studio lokaal voor samenvatten en chatten met transcript.")
                    .foregroundStyle(.secondary)

                TextField("Endpoint", text: $draftSettings.lmStudioConfig.endpoint)
                SecureField("API key (optioneel)", text: $lmStudioApiKeyInput)

                if viewModel.lmStudioLoadedModels.isEmpty {
                    Text("Laad eerst een model in LM Studio (Developer > Local Server).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Loaded model", selection: $draftSettings.lmStudioConfig.selectedModelIdentifier) {
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
                    Button("Refresh") {
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

                Text("RAM guidance: 16 GB+ recommended. MLX models work best on Apple Silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("LM Studio docs", destination: URL(string: "https://lmstudio.ai/docs/developer/rest")!)
                    .font(.caption)
            }

            Text("Geavanceerde instellingen (samenvattingsprompt) staan in Settings > Advanced.")
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
            return "Actief"
        case .notDetermined:
            return "Toestaan"
        case .denied:
            return "Open settings"
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
