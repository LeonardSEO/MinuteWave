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
    private static let screenCaptureConfirmedKey = "permissions.screenCapture.confirmed"

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

    static func screenCaptureState() -> PermissionState {
        if UserDefaults.standard.bool(forKey: screenCaptureConfirmedKey) {
            return .granted
        }
        if CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(true, forKey: screenCaptureConfirmedKey)
            return .granted
        }
        let requested = UserDefaults.standard.bool(forKey: screenCaptureRequestedKey)
        return requested ? .denied : .notDetermined
    }

    @MainActor
    static func refreshScreenCaptureState() async -> PermissionState {
        let quick = screenCaptureState()
        if quick == .granted {
            return .granted
        }

        guard #available(macOS 13.0, *) else {
            return quick
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                UserDefaults.standard.set(true, forKey: screenCaptureConfirmedKey)
                return .granted
            }
        } catch {
            // Keep fallback state from quick check.
        }

        return quick
    }

    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(true, forKey: screenCaptureConfirmedKey)
            return true
        }
        UserDefaults.standard.set(true, forKey: screenCaptureRequestedKey)
        UserDefaults.standard.set(false, forKey: screenCaptureConfirmedKey)
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
