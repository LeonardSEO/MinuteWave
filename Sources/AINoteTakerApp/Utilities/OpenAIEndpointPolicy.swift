import Foundation

enum OpenAIEndpointPolicy {
    static func validateHTTPSBaseURL(_ raw: String) -> Bool {
        guard let components = normalizedComponents(raw) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
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
