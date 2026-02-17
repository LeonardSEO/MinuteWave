import Foundation

struct AzureEndpointPasteResult {
    var endpoint: String?
    var chatDeployment: String?
    var transcriptionDeployment: String?
    var chatAPIVersion: String?
    var transcriptionAPIVersion: String?
    var parsedCount: Int
    var usedTranslationsRoute: Bool
    var warnings: [String]

    var didParseAny: Bool { parsedCount > 0 }
}

enum AzureEndpointPasteParser {
    private enum RouteKind {
        case chat
        case transcription
        case translation
        case other
    }

    static func parse(_ rawInput: String) -> AzureEndpointPasteResult {
        let candidates = rawInput
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                let lower = token.lowercased()
                return lower.hasPrefix("https://") || lower.hasPrefix("http://")
            }

        var endpoint: String?
        var chatDeployment: String?
        var transcriptionDeployment: String?
        var chatAPIVersion: String?
        var transcriptionAPIVersion: String?
        var parsedCount = 0
        var usedTranslationsRoute = false
        var warnings: [String] = []

        for token in candidates {
            guard let components = URLComponents(string: token),
                  let scheme = components.scheme,
                  let host = components.host else {
                continue
            }
            let normalizedEndpoint = "\(scheme.lowercased())://\(host.lowercased())"
            if let existing = endpoint, existing != normalizedEndpoint {
                warnings.append("azure.parse.warning.multiple_endpoints")
                continue
            }

            let path = components.path
            let deployment = deploymentFromPath(path)
            let routeKind = routeKindFromPath(path)
            let apiVersion = components.queryItems?
                .first(where: { $0.name.lowercased() == "api-version" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            endpoint = normalizedEndpoint
            parsedCount += 1

            switch routeKind {
            case .chat:
                if let deployment, !deployment.isEmpty {
                    chatDeployment = deployment
                }
                if let apiVersion, !apiVersion.isEmpty {
                    chatAPIVersion = apiVersion
                }
            case .transcription:
                if let deployment, !deployment.isEmpty {
                    transcriptionDeployment = deployment
                }
                if let apiVersion, !apiVersion.isEmpty {
                    transcriptionAPIVersion = apiVersion
                }
            case .translation:
                if let deployment, !deployment.isEmpty {
                    transcriptionDeployment = deployment
                }
                if let apiVersion, !apiVersion.isEmpty {
                    transcriptionAPIVersion = apiVersion
                }
                usedTranslationsRoute = true
            case .other:
                if let deployment, !deployment.isEmpty {
                    chatDeployment = chatDeployment ?? deployment
                }
                if let apiVersion, !apiVersion.isEmpty {
                    chatAPIVersion = chatAPIVersion ?? apiVersion
                }
            }
        }

        return AzureEndpointPasteResult(
            endpoint: endpoint,
            chatDeployment: chatDeployment,
            transcriptionDeployment: transcriptionDeployment,
            chatAPIVersion: chatAPIVersion,
            transcriptionAPIVersion: transcriptionAPIVersion,
            parsedCount: parsedCount,
            usedTranslationsRoute: usedTranslationsRoute,
            warnings: warnings
        )
    }

    private static func deploymentFromPath(_ path: String) -> String? {
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let index = segments.firstIndex(where: { $0.lowercased() == "deployments" }),
              index + 1 < segments.count else {
            return nil
        }
        return segments[index + 1]
    }

    private static func routeKindFromPath(_ path: String) -> RouteKind {
        let lower = path.lowercased()
        if lower.contains("/chat/completions") {
            return .chat
        }
        if lower.contains("/audio/transcriptions") {
            return .transcription
        }
        if lower.contains("/audio/translations") {
            return .translation
        }
        return .other
    }
}
