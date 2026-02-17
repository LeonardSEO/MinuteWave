import Foundation

enum L10n {
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
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
