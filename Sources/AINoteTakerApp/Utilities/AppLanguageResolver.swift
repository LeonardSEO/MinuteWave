import Foundation

enum AppLanguageResolver {
    static let supportedLanguageCodes = ["nl", "en"]
    static let persistedResolvedLanguageCodeKey = "resolvedAppLanguageCodeV1"

    static func resolveLanguageCode(
        preference: AppLanguagePreference,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch preference {
        case .system:
            return resolveSystemLanguageCode(preferredLanguages: preferredLanguages)
        case .dutch:
            return "nl"
        case .english:
            return "en"
        }
    }

    static func resolveSystemLanguageCode(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let matched = Bundle.preferredLocalizations(
            from: supportedLanguageCodes,
            forPreferences: preferredLanguages
        )
        if let first = matched.first, supportedLanguageCodes.contains(first) {
            return first
        }

        for identifier in preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("nl") {
                return "nl"
            }
            if lower.hasPrefix("en") {
                return "en"
            }
        }

        return "en"
    }

    static func locale(for languageCode: String) -> Locale {
        switch languageCode {
        case "nl":
            return Locale(identifier: "nl_NL")
        default:
            return Locale(identifier: "en_US")
        }
    }
}
