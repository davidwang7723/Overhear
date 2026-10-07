import Foundation
import AVFoundation

/// Converts arbitrary PCM to the 16 kHz mono Float32 whisper needs.
///
/// Apple's voice processing hands us a 3-channel deinterleaved buffer (channel 0
/// is the echo-cancelled voice). Downmixing that through AVAudioConverter yielded
/// pure silence, so we take channel 0 directly and use AVAudioConverter only for
/// the sample-rate change (mono→mono, which is reliable). Works for the system
/// stream too (its channel 0 is fine for speech).
final class AudioConvert {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false)!

    private var converter: AVAudioConverter?
    private var srcMonoFormat: AVAudioFormat?

    func toMono16k(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        let inRate = buffer.format.sampleRate

        // Fast path: already 16 kHz — just copy channel 0.
        if inRate == Self.targetFormat.sampleRate {
            return Array(UnsafeBufferPointer(start: channels[0], count: n))
        }

        // Build/refresh a mono@inputRate → mono@16k converter.
        if srcMonoFormat?.sampleRate != inRate {
            srcMonoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: inRate, channels: 1,
                                          interleaved: false)
            converter = srcMonoFormat.flatMap {
                AVAudioConverter(from: $0, to: Self.targetFormat)
            }
        }
        guard let srcMonoFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcMonoFormat,
                                           frameCapacity: AVAudioFrameCount(n))
        else { return nil }

        // Copy channel 0 (the processed voice) into a mono buffer.
        inBuf.frameLength = AVAudioFrameCount(n)
        memcpy(inBuf.floatChannelData![0], channels[0], n * MemoryLayout<Float>.size)

        let ratio = Self.targetFormat.sampleRate / inRate
        let capacity = AVAudioFrameCount(Double(n) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat,
                                         frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if error != nil { return nil }

        guard let o = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: o[0], count: Int(out.frameLength)))
    }
}
