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
            throw AppError.unsupportedHardware(
                reason: "This app requires Apple Silicon and at least 16 GB RAM. Current: \(caps.isAppleSilicon ? "Apple Silicon" : "Intel") with \(caps.physicalMemoryGB) GB."
            )
        }
    }
}
