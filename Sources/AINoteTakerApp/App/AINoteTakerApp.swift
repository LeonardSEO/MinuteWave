import SwiftUI

@main
struct MinuteWaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel
    @StateObject private var updateService = GitHubUpdateService()

    init() {
        if Bundle.main.bundleIdentifier != nil {
            NSWindow.allowsAutomaticWindowTabbing = false
        }
        let container = AppContainer.shared
        let vm = AppViewModel(
            repository: container.repository,
            keychain: container.keychain,
            audioEngine: container.audioEngine,
            localProvider: container.localProvider,
            azureProvider: container.azureProvider,
            openAIProvider: container.openAIProvider
        )
        _viewModel = StateObject(
            wrappedValue: vm
        )
        appDelegate.viewModel = vm
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
                .frame(minWidth: 1280, minHeight: 820)
                .background {
                    AppBackdropView()
                }
                .environmentObject(updateService)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.tr("ui.updates.menu.check_for_updates")) {
                    Task {
                        await updateService.checkForUpdates(userInitiated: true)
                    }
                }
                .disabled(updateService.isChecking)
            }

            CommandMenu(L10n.tr("ui.main.recording_menu")) {
                Button(L10n.tr("ui.main.recording_start")) {
                    Task { await viewModel.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(L10n.tr("ui.main.recording_stop")) {
                    Task { await viewModel.stopRecording() }
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
