import SwiftUI

@main
struct MinuteWaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

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
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Recording") {
                Button("Start") {
                    Task { await viewModel.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Stop") {
                    Task { await viewModel.stopRecording() }
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
