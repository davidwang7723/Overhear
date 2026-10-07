import Foundation
import AVFoundation
import CoreMedia

/// Captures the user's own voice (speaker `.me`) from the Mac's BUILT-IN mic,
/// as 16 kHz mono float, and slices it into utterances via `VoiceSegmenter`.
///
/// Uses AVCaptureSession — NOT AVAudioEngine — because device selection must be
/// explicit and guaranteed:
/// - Opening a Bluetooth headset's mic (which AVAudioEngine's inputNode does
///   whenever headphones are the default input) drops the headphones from the
///   A2DP music codec to the HFP call codec: output volume tanks, quality turns
///   terrible, and the HFP mic is too poor to transcribe. The AUHAL device-pin
///   hack is unreliable (inputNode.audioUnit can be nil pre-prepare, failing
///   silently). AVCaptureDeviceInput records exactly the device it's given.
/// - No voice processing anywhere: Apple's AEC routes system output through a
///   degraded call path and fights meeting apps. `EchoGate` handles speaker
///   bleed by waveform matching without touching any audio path.
final class AudioCaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    enum CaptureError: LocalizedError {
        case noMicrophone
        case cannotConfigure
        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "No microphone found"
            case .cannotConfigure: return "Could not configure microphone capture"
            }
        }
    }

    /// Emitted on the main queue when a speech segment closes.
    var onSegment: (([Float], _ start: Date) -> Void)? {
        get { segmenter.onSegment }
        set { segmenter.onSegment = newValue }
    }
    var onPartial: (([Float], _ start: Date) -> Void)? {
        get { segmenter.onPartial }
        set { segmenter.onPartial = newValue }
    }

    /// Applied to every mic chunk before segmentation — the echo canceller
    /// subtracts speaker audio here. Runs on the capture queue.
    var preprocess: (([Float]) -> [Float])?

    private var session: AVCaptureSession?
    private let segmenter = VoiceSegmenter()
    private let queue = DispatchQueue(label: "com.davidwang7723.overhear.mic")
    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        guard let device = Self.builtInMic() else { throw CaptureError.noMicrophone }
        NSLog("Overhear mic capture: using device '%@' (%@)",
              device.localizedName, device.uniqueID)

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotConfigure }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Ask the capture pipeline itself for our target format — the delegate
        // receives ready-to-use 16 kHz mono float32, no manual conversion.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotConfigure }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
        self.session = session
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session?.stopRunning()
        session = nil
        segmenter.flush()
        isRunning = false
    }

    // MARK: - Delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let mono = Self.floats(from: sampleBuffer) else { return }
        segmenter.add(preprocess?(mono) ?? mono)
    }

    // MARK: - Helpers

    /// The Mac's internal microphone. Never returns a Bluetooth/headset device.
    private static func builtInMic() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        // On every Mac the internal mic's uniqueID is "BuiltInMicrophoneDevice".
        if let mic = devices.first(where: { $0.uniqueID.contains("BuiltInMicrophone") }) {
            return mic
        }
        // Fallback: any non-Bluetooth-looking device, then the system default.
        let bt = ["bluetooth", "airpods", "hfp"]
        if let mic = devices.first(where: { d in
            !bt.contains(where: { d.localizedName.lowercased().contains($0) })
        }) {
            return mic
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Raw float32 samples out of an already-16k-mono-float sample buffer.
    private static func floats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= MemoryLayout<Float>.size else { return nil }
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                       dataLength: $0.count,
                                       destination: $0.baseAddress!)
        }
        return status == noErr ? samples : nil
    }
}
