import Foundation

enum LMStudioEndpointPolicy {
    static func validateLoopbackBaseURL(_ raw: String) -> Bool {
        normalizedLoopbackComponents(raw) != nil
    }

    static func normalizedLoopbackComponents(_ raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host?.lowercased(),
              isLoopbackHost(host) else {
            return nil
        }
        return components
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost: String
        if host.hasPrefix("[") && host.hasSuffix("]") {
            normalizedHost = String(host.dropFirst().dropLast())
        } else {
            normalizedHost = host
        }

        if normalizedHost == "localhost" || normalizedHost == "localhost." || normalizedHost == "::1" {
            return true
        }

        let octets = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              first == 127 else {
            return false
        }

        return octets.allSatisfy { part in
            guard !part.isEmpty, let value = Int(part) else {
                return false
            }
            return (0...255).contains(value)
        }
    }
}
