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
    private static let screenCaptureRequestedKey = "permissions.screenCapture.requested"
    private static let screenCaptureLegacyConfirmedKey = "permissions.screenCapture.confirmed"

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

    static func resolveScreenCaptureState(
        preflightGranted: Bool,
        requestedBefore: Bool
    ) -> PermissionState {
        if preflightGranted {
            return .granted
        }
        return requestedBefore ? .denied : .notDetermined
    }

    static func screenCaptureState() -> PermissionState {
        let preflightGranted = CGPreflightScreenCaptureAccess()
        let requested = UserDefaults.standard.bool(forKey: screenCaptureRequestedKey)
        return resolveScreenCaptureState(preflightGranted: preflightGranted, requestedBefore: requested)
    }

    @MainActor
    static func refreshScreenCaptureState() async -> PermissionState {
        let preflightGranted = CGPreflightScreenCaptureAccess()
        if preflightGranted {
            return .granted
        }
        let requestedBefore = UserDefaults.standard.bool(forKey: screenCaptureRequestedKey)

        guard #available(macOS 13.0, *) else {
            return resolveScreenCaptureState(preflightGranted: preflightGranted, requestedBefore: requestedBefore)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                return .granted
            }
        } catch {
            // Keep fallback state from quick check.
        }

        return resolveScreenCaptureState(preflightGranted: preflightGranted, requestedBefore: requestedBefore)
    }

    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        UserDefaults.standard.set(true, forKey: screenCaptureRequestedKey)
        UserDefaults.standard.removeObject(forKey: screenCaptureLegacyConfirmedKey)
        return CGRequestScreenCaptureAccess()
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
}
