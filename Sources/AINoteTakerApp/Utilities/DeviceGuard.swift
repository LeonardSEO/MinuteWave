import Foundation

struct DeviceCapabilities {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int

    var meetsMinimumRequirements: Bool {
        isAppleSilicon && physicalMemoryGB >= 16
    }
}

enum DeviceGuard {
    static func inspect() -> DeviceCapabilities {
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif

        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return DeviceCapabilities(isAppleSilicon: isAppleSilicon, physicalMemoryGB: gb)
    }

    static func validateMinimumRequirements() throws {
        let caps = inspect()
        guard caps.meetsMinimumRequirements else {
            let architecture = caps.isAppleSilicon
                ? L10n.tr("ui.error.hardware.apple_silicon")
                : L10n.tr("ui.error.hardware.intel")
            throw AppError.unsupportedHardware(
                reason: L10n.tr("ui.error.hardware.minimum_requirements", architecture, caps.physicalMemoryGB)
            )
        }
    }
}
