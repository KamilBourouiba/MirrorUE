import AVFoundation
import AppKit
import CoreGraphics
import ControlKit

/// Camera + Screen Recording — never auto-prompt; never re-ask when already granted.
enum MirrorUEPermissions {
    private static let screenAskedKey = "mirrorue.didAskScreenRecording"
    private static let cameraAskedKey = "mirrorue.didAskCamera"

    static var gateCompleted: Bool {
        get { MirrorUESettings.permissionsGateCompleted }
        set { MirrorUESettings.permissionsGateCompleted = newValue }
    }

    static func markGateCompleted() {
        gateCompleted = true
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var cameraGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Camera is required for Continuity / CoreMediaIO phone frames.
    /// Screen Recording is optional — the agent reads `/v1/frame` from MirrorUE,
    /// not Mac `screencapture` (which would prompt for Python/Terminal instead).
    static var allRequiredGranted: Bool {
        cameraGranted
    }

    /// Show the gate only when something is still missing AND we haven't finished onboarding.
    /// If permissions are already OK, never show / never re-ask.
    static var needsPermissionGate: Bool {
        if allRequiredGranted {
            gateCompleted = true
            return false
        }
        return !gateCompleted
    }

    static var canProceedToConnect: Bool {
        !needsPermissionGate
    }

    /// User tapped Allow — only prompts when status is `.notDetermined`.
    static func requestCameraExplicitly(completion: (() -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            // Already OK — never re-ask.
            completion?()
        case .notDetermined:
            if UserDefaults.standard.bool(forKey: cameraAskedKey) {
                completion?()
                return
            }
            UserDefaults.standard.set(true, forKey: cameraAskedKey)
            AVCaptureDevice.requestAccess(for: .video) { _ in
                completion?()
            }
        case .denied, .restricted:
            openPrivacySettings(section: "Privacy_Camera")
            completion?()
        @unknown default:
            completion?()
        }
    }

    /// User tapped Allow — no-op if already granted; at most one system prompt.
    static func requestScreenRecordingExplicitly() {
        if CGPreflightScreenCaptureAccess() {
            return // Already OK — never re-ask.
        }
        if UserDefaults.standard.bool(forKey: screenAskedKey) {
            openPrivacySettings(section: "Privacy_ScreenCapture")
            return
        }
        UserDefaults.standard.set(true, forKey: screenAskedKey)
        fputs("MirrorUE: user requested Screen Recording…\n", stderr)
        _ = CGRequestScreenCaptureAccess()
    }

    static func openPrivacySettings(section: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }
}
