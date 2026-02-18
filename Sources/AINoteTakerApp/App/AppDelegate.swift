import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel? {
        didSet {
            if let updateService, let viewModel {
                viewModel.attachUpdateController(updateService)
            }
        }
    }
    private var isTerminationFlowInProgress = false
    private var updateService: UpdateService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let service = UpdateService()
        updateService = service
        viewModel?.attachUpdateController(service)
        service.checkForUpdatesInBackground()

        DispatchQueue.main.async {
            for window in NSApp.windows {
                self.configure(window)
            }
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows {
            configure(window)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.requiresTerminationConfirmation else {
            return .terminateNow
        }
        if isTerminationFlowInProgress {
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("app.quit.recording.title")
        alert.informativeText = L10n.tr("app.quit.recording.message")
        alert.addButton(withTitle: L10n.tr("app.quit.recording.safe_stop"))
        alert.addButton(withTitle: L10n.tr("app.quit.recording.cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminationFlowInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStopSafely = await viewModel.stopRecordingForTermination()
            sender.reply(toApplicationShouldTerminate: didStopSafely)
            self.isTerminationFlowInProgress = false
        }
        return .terminateLater
    }

    private func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isMovableByWindowBackground = false
    }

    func checkForUpdates() {
        updateService?.checkForUpdates()
    }
}
