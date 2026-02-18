import Foundation
import Sparkle

@MainActor
protocol AppUpdateControlling: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

@MainActor
final class UpdateService: NSObject, AppUpdateControlling {
    private static let publicKeyPlaceholder = "__SPARKLE_PUBLIC_ED_KEY__"

    private let updaterController: SPUStandardUpdaterController?
    let isAvailable: Bool

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = info["SUFeedURL"] as? String
        let publicKey = info["SUPublicEDKey"] as? String

        guard let feedURL, !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLogger.updates.error("Sparkle disabled: SUFeedURL is missing.")
            self.updaterController = nil
            self.isAvailable = false
            super.init()
            return
        }

        guard let publicKey,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              publicKey != Self.publicKeyPlaceholder else {
            AppLogger.updates.error("Sparkle disabled: SUPublicEDKey is missing or placeholder.")
            self.updaterController = nil
            self.isAvailable = false
            super.init()
            return
        }

        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.isAvailable = true
        super.init()
        AppLogger.updates.info("Sparkle initialized with feed URL: \(feedURL, privacy: .public)")
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        updaterController?.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        guard isAvailable else { return }
        updaterController?.updater.checkForUpdatesInBackground()
    }
}
