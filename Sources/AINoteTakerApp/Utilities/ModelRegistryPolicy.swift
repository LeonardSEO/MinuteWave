import Foundation
import FluidAudio

enum ModelRegistryPolicy {
    static let trustedDefaultBaseURL = "https://huggingface.co"
    private static let allowedHosts = Set(["huggingface.co"])

    struct ResolutionResult {
        let baseURL: String
        let warning: String?
    }

    static func resolveTrustedBaseURL(candidate: String?) -> ResolutionResult {
        guard let candidate else {
            return ResolutionResult(baseURL: trustedDefaultBaseURL, warning: nil)
        }

        guard let components = URLComponents(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              (components.path.isEmpty || components.path == "/"),
              components.query == nil,
              components.fragment == nil else {
            return ResolutionResult(
                baseURL: trustedDefaultBaseURL,
                warning: "Rejected untrusted model registry URL; falling back to trusted default."
            )
        }

        return ResolutionResult(baseURL: "https://\(host)", warning: nil)
    }

    @discardableResult
    static func applyGlobalPolicy() -> ResolutionResult {
        let env = ProcessInfo.processInfo.environment
        let candidate = env["REGISTRY_URL"] ?? env["MODEL_REGISTRY_URL"]
        let resolved = resolveTrustedBaseURL(candidate: candidate)
        ModelRegistry.baseURL = resolved.baseURL
        return resolved
    }
}
