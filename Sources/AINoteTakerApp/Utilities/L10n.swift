import Foundation

enum L10n {
    private static let defaultFallbackLanguageCode = "en"
    private static var localizationSearchBundles: [Bundle] {
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        return bundles
    }

    static func setResolvedLanguageCode(_ code: String) {
        UserDefaults.standard.set(code, forKey: AppLanguageResolver.persistedResolvedLanguageCodeKey)
    }

    static func resolvedLanguageCode() -> String {
        let stored = UserDefaults.standard.string(
            forKey: AppLanguageResolver.persistedResolvedLanguageCodeKey
        )
        if let stored, AppLanguageResolver.supportedLanguageCodes.contains(stored) {
            return stored
        }
        return AppLanguageResolver.resolveSystemLanguageCode()
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = localizedString(for: key)
        guard !args.isEmpty else { return format }
        let locale = AppLanguageResolver.locale(for: resolvedLanguageCode())
        return String(format: format, locale: locale, arguments: args)
    }

    static func localizedString(for key: String, languageCode: String? = nil) -> String {
        let code = languageCode ?? resolvedLanguageCode()
        if let localized = localizedString(for: key, in: code), localized != key {
            return localized
        }

        if code != defaultFallbackLanguageCode,
           let fallback = localizedString(for: key, in: defaultFallbackLanguageCode),
           fallback != key {
            return fallback
        }

        if let baseLocalized = localizedStringFromBaseBundles(for: key),
           baseLocalized != key {
            return baseLocalized
        }

        return unresolvedKeyFallback(for: key, languageCode: code)
    }

    private static func localizedString(for key: String, in languageCode: String) -> String? {
        for baseBundle in localizationSearchBundles {
            guard let path = baseBundle.path(forResource: languageCode, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                continue
            }
            let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }
        return nil
    }

    private static func localizedStringFromBaseBundles(for key: String) -> String? {
        for baseBundle in localizationSearchBundles {
            let localized = baseBundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }
        return nil
    }

    private static func unresolvedKeyFallback(for key: String, languageCode: String) -> String {
        let generic: String
        if languageCode == "nl" {
            generic = "Vertaling ontbreekt"
        } else {
            generic = "Translation unavailable"
        }

        if key.hasPrefix("ui.") {
            return generic
        }
        return generic
    }
}
