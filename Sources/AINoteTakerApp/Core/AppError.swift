import Foundation

enum AppError: LocalizedError {
    case unsupportedHardware(reason: String)
    case invalidConfiguration(reason: String)
    case storageFailure(reason: String)
    case networkFailure(reason: String)
    case providerUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware(let reason):
            return "\(L10n.tr("error.prefix.unsupported_hardware")): \(reason)"
        case .invalidConfiguration(let reason):
            return "\(L10n.tr("error.prefix.invalid_configuration")): \(reason)"
        case .storageFailure(let reason):
            return "\(L10n.tr("error.prefix.storage_failure")): \(reason)"
        case .networkFailure(let reason):
            return "\(L10n.tr("error.prefix.network_failure")): \(reason)"
        case .providerUnavailable(let reason):
            return "\(L10n.tr("error.prefix.provider_unavailable")): \(reason)"
        }
    }
}
