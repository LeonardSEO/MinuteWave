import Foundation

enum OpenAIEndpointPolicy {
    private static let knownOpenAIHosts: Set<String> = [
        "api.openai.com",
    ]

    static func validateHTTPSBaseURL(_ raw: String, allowCustomHosts: Bool = true) -> Bool {
        guard let components = normalizedComponents(raw) else {
            return false
        }
        guard components.scheme?.lowercased() == "https" else {
            return false
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if knownOpenAIHosts.contains(host) { return true }
        if host.hasSuffix(".openai.azure.com") { return true }
        return allowCustomHosts
    }

    private static func normalizedComponents(_ raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.host?.isEmpty == false else {
            return nil
        }
        return components
    }
}
