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

    static func quickScreenCaptureState(preflightGranted: Bool) -> PermissionState {
        if preflightGranted {
            return .granted
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
        if quick == .granted { return .granted }

        guard #available(macOS 13.0, *) else {
            return quick
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                return .granted
            }
            return .notDetermined
        } catch {
            return classifyScreenCaptureProbeFailure(error)
        }
    }

    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
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
