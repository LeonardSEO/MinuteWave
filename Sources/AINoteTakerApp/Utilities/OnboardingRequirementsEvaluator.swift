import Foundation

struct OnboardingRequirementSnapshot: Equatable {
    var meetsMinimumRequirements: Bool
    var microphonePermission: PermissionState
    var screenCapturePermission: PermissionState
    var selectedCaptureMode: LocalAudioCaptureMode

    var requiresScreenCapture: Bool {
        selectedCaptureMode == .microphoneAndSystem
    }
}

enum OnboardingRequirementsEvaluator {
    static func permissionsStepIsSatisfied(_ snapshot: OnboardingRequirementSnapshot) -> Bool {
        snapshot.meetsMinimumRequirements && snapshot.microphonePermission == .granted
    }

    static func canContinue(step: Int, snapshot: OnboardingRequirementSnapshot) -> Bool {
        switch step {
        case 0, 2:
            return permissionsStepIsSatisfied(snapshot)
        default:
            return true
        }
    }

    static func screenCaptureNeedsAttention(_ snapshot: OnboardingRequirementSnapshot) -> Bool {
        snapshot.requiresScreenCapture && snapshot.screenCapturePermission != .granted
    }
}
