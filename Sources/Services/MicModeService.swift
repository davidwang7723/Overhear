import AVFoundation

/// macOS "mic modes" (Ventura+): Standard / Voice Isolation / Wide Spectrum.
/// Voice Isolation runs on the Neural Engine and strips background noise + the
/// audio blasting from your speakers, keeping only your voice — exactly what we
/// want on the mic channel. It engages for apps using voice-processing capture
/// (we enable that in AudioCaptureService).
///
/// The mode is a system-wide, user-owned setting: apps can read the active mode
/// and present Apple's picker, but cannot force it programmatically.
enum MicModeService {
    static var active: AVCaptureDevice.MicrophoneMode {
        AVCaptureDevice.activeMicrophoneMode
    }

    static var activeLabel: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "Unknown"
        }
    }

    static var isVoiceIsolationActive: Bool {
        AVCaptureDevice.activeMicrophoneMode == .voiceIsolation
    }

    /// Opens Apple's system mic-mode picker (Control Center) so the user can
    /// switch to Voice Isolation.
    static func showPicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
