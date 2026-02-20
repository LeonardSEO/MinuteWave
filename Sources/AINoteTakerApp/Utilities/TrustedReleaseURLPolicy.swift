import Foundation

enum TrustedReleaseURLPolicy {
    static func isTrustedReleaseURL(_ url: URL, owner: String, repository: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com" else {
            return false
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathParts = normalizedPath.split(separator: "/")
        guard pathParts.count >= 3 else {
            return false
        }

        return pathParts[0].caseInsensitiveCompare(owner) == .orderedSame
            && pathParts[1].caseInsensitiveCompare(repository) == .orderedSame
            && pathParts[2].caseInsensitiveCompare("releases") == .orderedSame
    }
}
