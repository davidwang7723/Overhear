import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Checks and helps the user grant the two TCC permissions Overhear needs:
/// microphone and screen recording (which also covers system-audio capture).
enum PermissionsService {
    enum State { case granted, denied, notDetermined }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Screen recording (gates ScreenCaptureKit audio + screenshots).
    static var screenRecording: State {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Prompts for screen recording (adds Overhear to the list on first call).
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func openMicrophoneSettings() { open("Privacy_Microphone") }
    static func openScreenRecordingSettings() { open("Privacy_ScreenCapture") }

    private static func open(_ anchor: String) {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
