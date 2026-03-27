import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

enum PermissionState: String {
    case granted = "Granted"
    case denied = "Denied"
    case notDetermined = "Not requested"
}

enum Permissions {
    private static let screenCaptureStateLock = NSLock()
    private static var lastResolvedScreenCaptureState: PermissionState?
    private static let screenCapturePermissionErrorMarkers: [String] = [
        "permission",
        "not authorized",
        "not permitted",
        "denied",
        "declined"
    ]

    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    @MainActor
    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func quickScreenCaptureState(preflightGranted: Bool, lastKnownState: PermissionState? = cachedScreenCaptureState()) -> PermissionState {
        if preflightGranted {
            return .granted
        }
        if lastKnownState == .granted {
            return .granted
        }
        if lastKnownState == .denied {
            return .denied
        }
        return .notDetermined
    }

    static func classifyScreenCaptureProbeFailure(_ error: Error) -> PermissionState {
        let nsError = error as NSError
        let diagnostics = [
            nsError.domain,
            nsError.localizedDescription,
            String(describing: error)
        ].joined(separator: " ").lowercased()

        if screenCapturePermissionErrorMarkers.contains(where: { diagnostics.contains($0) }) {
            return .denied
        }

        return .notDetermined
    }

    static func screenCaptureState() -> PermissionState {
        quickScreenCaptureState(preflightGranted: CGPreflightScreenCaptureAccess())
    }

    @MainActor
    static func refreshScreenCaptureState() async -> PermissionState {
        let quick = quickScreenCaptureState(preflightGranted: CGPreflightScreenCaptureAccess())
        if quick == .granted || quick == .denied {
            cacheScreenCaptureState(quick)
            return quick
        }

        guard #available(macOS 13.0, *) else {
            return quick
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                cacheScreenCaptureState(.granted)
                return .granted
            }
            cacheScreenCaptureState(.notDetermined)
            return .notDetermined
        } catch {
            let classified = classifyScreenCaptureProbeFailure(error)
            cacheScreenCaptureState(classified)
            return classified
        }
    }

    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            cacheScreenCaptureState(.granted)
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        cacheScreenCaptureState(granted ? .granted : .notDetermined)
        return granted
    }

    static func screenCapturePermissionGuidanceMessage() -> String {
        L10n.tr("ui.permissions.screen_recording_guidance")
    }

    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func relaunchCurrentApp() {
        let appURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func cachedScreenCaptureState() -> PermissionState? {
        screenCaptureStateLock.lock()
        defer { screenCaptureStateLock.unlock() }
        return lastResolvedScreenCaptureState
    }

    private static func cacheScreenCaptureState(_ state: PermissionState) {
        screenCaptureStateLock.lock()
        lastResolvedScreenCaptureState = state
        screenCaptureStateLock.unlock()
    }
}
