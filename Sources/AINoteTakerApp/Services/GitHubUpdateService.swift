import Foundation
import AppKit
import Combine

struct AppSemanticVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ raw: String) {
        let normalized = Self.normalizedString(from: raw)
        guard !normalized.isEmpty else { return nil }
        let parsed = normalized.split(separator: ".").compactMap { Int($0) }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func normalizedString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withoutPrefix: String
        if trimmed.first == "v" || trimmed.first == "V" {
            withoutPrefix = String(trimmed.dropFirst())
        } else {
            withoutPrefix = trimmed
        }

        let numericPrefix = withoutPrefix.prefix { char in
            char.isNumber || char == "."
        }
        let chunks = numericPrefix
            .split(separator: ".")
            .filter { !$0.isEmpty }

        return chunks.joined(separator: ".")
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return false
            }
        }
        return true
    }
}

@MainActor
final class GitHubUpdateService: ObservableObject {
    private struct LatestReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private struct LatestReleaseInfo {
        let version: AppSemanticVersion
        let versionLabel: String
        let releaseURL: URL
    }

    private enum UpdateCheckError: Error {
        case invalidResponse
        case httpStatus(Int)
        case invalidVersionTag(String)
        case noStableRelease
    }

    private let owner: String
    private let repository: String
    private let session: URLSession
    private let jsonDecoder = JSONDecoder()

    @Published private(set) var isChecking = false
    @Published private(set) var latestKnownVersion: String?
    @Published private(set) var latestReleaseURL: URL?
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var lastStatusIsError = false

    init(
        owner: String = "LeonardSEO",
        repository: String = "MinuteWave",
        session: URLSession = .shared
    ) {
        self.owner = owner
        self.repository = repository
        self.session = session
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var fallbackReleasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    func checkForUpdates(userInitiated: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let latest = try await fetchLatestReleaseInfo()
            latestKnownVersion = latest.versionLabel
            latestReleaseURL = latest.releaseURL

            let hasUpdate: Bool
            if let current = AppSemanticVersion(currentVersion) {
                hasUpdate = latest.version > current
            } else {
                let normalizedCurrent = AppSemanticVersion.normalizedString(from: currentVersion)
                hasUpdate = !normalizedCurrent.isEmpty && latest.versionLabel != normalizedCurrent
            }

            if hasUpdate {
                lastStatusMessage = L10n.tr("ui.updates.status.available", latest.versionLabel)
                lastStatusIsError = false
                if userInitiated {
                    presentUpdateAvailableAlert(latestVersion: latest.versionLabel, releaseURL: latest.releaseURL)
                }
            } else {
                lastStatusMessage = L10n.tr("ui.updates.status.current", currentVersion)
                lastStatusIsError = false
                if userInitiated {
                    presentUpToDateAlert()
                }
            }
        } catch {
            let message = localizedErrorMessage(for: error)
            lastStatusMessage = message
            lastStatusIsError = true
            AppLogger.network.error("Update check failed: \(String(describing: error), privacy: .public)")

            if userInitiated {
                presentUpdateCheckFailedAlert(message: message)
            }
        }
    }

    func openLatestReleasePage() {
        NSWorkspace.shared.open(latestReleaseURL ?? fallbackReleasesPageURL)
    }

    private func fetchLatestReleaseInfo() async throws -> LatestReleaseInfo {
        let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MinuteWave/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let payload = try jsonDecoder.decode(LatestReleasePayload.self, from: data)
        if payload.draft || payload.prerelease {
            throw UpdateCheckError.noStableRelease
        }

        guard let version = AppSemanticVersion(payload.tagName) else {
            throw UpdateCheckError.invalidVersionTag(payload.tagName)
        }

        return LatestReleaseInfo(
            version: version,
            versionLabel: version.description,
            releaseURL: payload.htmlURL
        )
    }

    private func presentUpdateAvailableAlert(latestVersion: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("ui.updates.alert.available.title")
        alert.informativeText = L10n.tr(
            "ui.updates.alert.available.message",
            latestVersion,
            currentVersion
        )
        alert.addButton(withTitle: L10n.tr("ui.updates.alert.available.install"))
        alert.addButton(withTitle: L10n.tr("ui.updates.alert.available.later"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func presentUpToDateAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("ui.updates.alert.current.title")
        alert.informativeText = L10n.tr("ui.updates.alert.current.message", currentVersion)
        alert.addButton(withTitle: L10n.tr("ui.common.ok"))
        alert.runModal()
    }

    private func presentUpdateCheckFailedAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("ui.updates.alert.failed.title")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("ui.updates.alert.failed.open_releases"))
        alert.addButton(withTitle: L10n.tr("ui.common.ok"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fallbackReleasesPageURL)
        }
    }

    private func localizedErrorMessage(for error: Error) -> String {
        if let updateError = error as? UpdateCheckError {
            switch updateError {
            case .invalidResponse:
                return L10n.tr("ui.updates.error.invalid_response")
            case .httpStatus(let statusCode):
                return L10n.tr("ui.updates.error.http_status", statusCode)
            case .invalidVersionTag(let tag):
                return L10n.tr("ui.updates.error.invalid_version", tag)
            case .noStableRelease:
                return L10n.tr("ui.updates.error.no_stable_release")
            }
        }
        if error is DecodingError {
            return L10n.tr("ui.updates.error.invalid_response")
        }
        if let urlError = error as? URLError {
            return L10n.tr("ui.updates.error.network", urlError.localizedDescription)
        }
        return L10n.tr("ui.updates.error.generic")
    }
}
