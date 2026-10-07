import Foundation
import Speech
import AVFoundation

/// Speech-to-text on Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26) —
/// the system's on-device model running on the Neural Engine. No third-party
/// packages, no model files to manage; the English asset installs once from
/// Apple's CDN. Substantially more accurate than whisper base and fast.
/// An actor so segments transcribe one at a time per engine.
actor TranscriptionEngine {
    private var assetsReady = false
    private var analyzerFormat: AVAudioFormat?

    var isLoaded: Bool { assetsReady }

    /// Ensure the language assets are installed (one-time download).
    @discardableResult
    func load() async -> Bool {
        guard !assetsReady else { return true }
        do {
            let transcriber = Self.makeTranscriber()
            if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
            assetsReady = true
            return true
        } catch {
            NSLog("Overhear: speech asset install failed: \(error)")
            return false
        }
    }

    /// Transcribe one 16 kHz mono segment. Returns trimmed text ("" if silence).
    func transcribe(_ frames: [Float]) async -> String {
        guard assetsReady else { return "" }
        do {
            let transcriber = Self.makeTranscriber()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let buffer = Self.makeBuffer(frames, target: analyzerFormat)
            else { return "" }

            // Collect results concurrently with feeding input.
            let collector = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
                return text
            }

            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            builder.yield(AnalyzerInput(buffer: buffer))
            builder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()

            return try await collector.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Overhear: transcription failed: \(error)")
            return ""
        }
    }

    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en_US"),
                          transcriptionOptions: [],
                          reportingOptions: [],
                          attributeOptions: [])
    }

    /// Wrap our 16 kHz mono Float32 frames in a buffer matching the analyzer's
    /// preferred format (converting if they differ).
    private static func makeBuffer(_ frames: [Float],
                                   target: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1,
                                      interleaved: false)!
        guard !frames.isEmpty,
              let src = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                         frameCapacity: AVAudioFrameCount(frames.count))
        else { return nil }
        src.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { ptr in
            src.floatChannelData![0].update(from: ptr.baseAddress!, count: frames.count)
        }

        guard let target, target != srcFormat,
              let converter = AVAudioConverter(from: srcFormat, to: target)
        else { return src }

        let ratio = target.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames.count) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: capacity) else { return src }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return error == nil ? out : src
    }
}
