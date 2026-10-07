import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures system audio (what *they* say through Zoom/Meet/etc → speaker
/// `.them`) via ScreenCaptureKit, converts to 16 kHz mono, and segments it.
/// Our own process audio is excluded so we never transcribe our own output.
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSegment: (([Float], _ start: Date) -> Void)? {
        get { segmenter.onSegment }
        set { segmenter.onSegment = newValue }
    }
    var onPartial: (([Float], _ start: Date) -> Void)? {
        get { segmenter.onPartial }
        set { segmenter.onPartial = newValue }
    }

    /// Raw 16 kHz mono chunks, straight off the stream — feeds the echo
    /// canceller its reference of what the speakers are playing. Called on the
    /// capture queue.
    var onRawAudio: (([Float]) -> Void)?

    private var stream: SCStream?
    private let convert = AudioConvert()
    private let segmenter = VoiceSegmenter()
    private let sampleQueue = DispatchQueue(label: "overhear.system-audio")
    private(set) var isRunning = false

    func start() async throws {
        guard !isRunning else { return }

        // Triggers the screen-recording TCC prompt on first use.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Overhear", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Never mix the microphone into the system stream — this channel is the
        // crisp digital app audio (their voice) only. Room noise / our own voice
        // lives entirely on the separate mic channel.
        if #available(macOS 15.0, *) {
            config.captureMicrophone = false
        }
        // Minimize the (unused) video path.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    func stop() {
        guard isRunning, let stream else { return }
        stream.stopCapture { _ in }
        self.stream = nil
        segmenter.flush()
        isRunning = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer),
              let mono = convert.toMono16k(pcm) else { return }
        onRawAudio?(mono)
        segmenter.add(mono)
    }

    /// Wrap a CoreMedia audio sample buffer as an AVAudioPCMBuffer.
    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
