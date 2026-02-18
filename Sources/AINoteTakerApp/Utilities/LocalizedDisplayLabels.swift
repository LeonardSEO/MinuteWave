import Foundation

extension AppTheme {
    var localizedLabel: String {
        switch self {
        case .system:
            return L10n.tr("ui.settings.theme.system")
        case .light:
            return L10n.tr("ui.settings.theme.light")
        case .dark:
            return L10n.tr("ui.settings.theme.dark")
        }
    }
}

extension AppLanguagePreference {
    var localizedLabel: String {
        switch self {
        case .system:
            return L10n.tr("ui.settings.language.system")
        case .dutch:
            return L10n.tr("ui.settings.language.dutch")
        case .english:
            return L10n.tr("ui.settings.language.english")
        }
    }
}

extension CloudProviderType {
    var localizedLabel: String {
        switch self {
        case .azureOpenAI:
            return L10n.tr("ui.common.provider.azure_openai")
        case .openAI:
            return L10n.tr("ui.common.provider.openai")
        case .lmStudio:
            return L10n.tr("ui.common.provider.lmstudio_local")
        }
    }
}

extension TranscriptionProviderType {
    var localizedLabel: String {
        switch self {
        case .localVoxtral:
            return L10n.tr("ui.common.transcription_provider.local_fluidaudio")
        case .azure:
            return L10n.tr("ui.common.transcription_provider.azure")
        case .openAI:
            return L10n.tr("ui.common.transcription_provider.openai")
        }
    }
}

extension LocalAudioCaptureMode {
    var localizedLabel: String {
        switch self {
        case .microphoneOnly:
            return L10n.tr("ui.common.capture_mode.microphone_only")
        case .microphoneAndSystem:
            return L10n.tr("ui.common.capture_mode.microphone_and_system")
        }
    }

    var localizedShortLabel: String {
        switch self {
        case .microphoneOnly:
            return L10n.tr("ui.common.capture_mode.short_microphone_only")
        case .microphoneAndSystem:
            return L10n.tr("ui.common.capture_mode.short_microphone_and_system")
        }
    }
}

extension SessionStatus {
    var localizedLabel: String {
        switch self {
        case .idle:
            return L10n.tr("ui.status.session.idle")
        case .recording:
            return L10n.tr("ui.status.session.recording")
        case .paused:
            return L10n.tr("ui.status.session.paused")
        case .finalizing:
            return L10n.tr("ui.status.session.finalizing")
        case .completed:
            return L10n.tr("ui.status.session.completed")
        case .failed:
            return L10n.tr("ui.status.session.failed")
        }
    }
}

extension SummaryStatus {
    var localizedLabel: String {
        switch self {
        case .notStarted:
            return L10n.tr("ui.status.summary.not_started")
        case .processing:
            return L10n.tr("ui.status.summary.processing")
        case .completed:
            return L10n.tr("ui.status.summary.completed")
        case .failed:
            return L10n.tr("ui.status.summary.failed")
        }
    }
}

extension ChatMessage.Role {
    var localizedLabel: String {
        switch self {
        case .user:
            return L10n.tr("ui.chat.role.user")
        case .assistant:
            return L10n.tr("ui.chat.role.assistant")
        case .system:
            return L10n.tr("ui.chat.role.system")
        }
    }
}

extension PermissionState {
    var localizedLabel: String {
        switch self {
        case .granted:
            return L10n.tr("ui.permission.granted")
        case .denied:
            return L10n.tr("ui.permission.denied")
        case .notDetermined:
            return L10n.tr("ui.permission.not_requested")
        }
    }
}
