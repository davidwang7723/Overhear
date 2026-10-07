import Foundation
import CoreAudio

/// Fires when the system's default audio OUTPUT device changes (user switches
/// between Bluetooth headphones and the Mac's speakers, plugs something in…).
/// System-audio capture taps the output path, so it must be restarted on the
/// new device or "their voice" transcription silently stops.
final class OutputDeviceWatcher {
    /// Called on the main queue on every default-output change.
    var onChange: (() -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    func start() {
        guard listenerBlock == nil else { return }
        var address = Self.address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    func stop() {
        guard let block = listenerBlock else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        listenerBlock = nil
    }

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
