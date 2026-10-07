import Foundation

/// Energy-based VAD that slices a stream of 16 kHz mono Float32 frames into
/// utterances. Shared by the mic and system-audio capture paths so both segment
/// speech identically. Not thread-safe — feed it from a single queue per source.
final class VoiceSegmenter {
    /// Called when a speech segment closes, with the segment's audio and start time.
    var onSegment: (([Float], _ start: Date) -> Void)?
    /// Called periodically while speech is ongoing, with the audio so far.
    /// Drives live (non-final) captions.
    var onPartial: (([Float], _ start: Date) -> Void)?

    private var segment: [Float] = []
    private var segmentStart = Date()
    private var silenceFrames = 0
    private var isVoiced = false
    private var framesSincePartial = 0
    private let partialInterval = 16_000       // ~1 s of audio between partials
    private let maxPartialFrames = 16_000 * 6  // transcribe only the last ~6 s live

    // Tunables (in 16 kHz frames).
    private let rmsThreshold: Float
    private let silenceToClose = 16_000 * 7 / 10   // ~700 ms trailing silence
    private let minSegmentFrames = 16_000 * 4 / 10 // ignore <400 ms blips
    private let maxSegmentFrames = 16_000 * 15     // force flush at 15 s

    init(rmsThreshold: Float = 0.012) {
        self.rmsThreshold = rmsThreshold
    }

    func add(_ mono: [Float]) {
        guard !mono.isEmpty else { return }
        let voicedNow = Self.rms(mono) > rmsThreshold

        if voicedNow {
            if !isVoiced {
                isVoiced = true
                if segment.isEmpty { segmentStart = Date() }
            }
            silenceFrames = 0
            segment.append(contentsOf: mono)
            framesSincePartial += mono.count
            if framesSincePartial >= partialInterval { emitPartial() }
        } else if isVoiced {
            segment.append(contentsOf: mono)   // keep tail so words aren't clipped
            silenceFrames += mono.count
            if silenceFrames >= silenceToClose { close() }
        }

        if segment.count >= maxSegmentFrames { close() }
    }

    func flush() { if isVoiced { close() } }

    private func emitPartial() {
        framesSincePartial = 0
        guard segment.count >= minSegmentFrames else { return }
        // Only the tail — re-transcribing the whole growing buffer every second
        // is wasteful; the final pass covers the full segment anyway.
        let snapshot = segment.count > maxPartialFrames
            ? Array(segment.suffix(maxPartialFrames)) : segment
        let start = segmentStart
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?(snapshot, start)
        }
    }

    private func close() {
        defer {
            segment.removeAll(keepingCapacity: true)
            silenceFrames = 0
            isVoiced = false
            framesSincePartial = 0
        }
        guard segment.count >= minSegmentFrames else { return }
        let closed = segment
        let start = segmentStart
        DispatchQueue.main.async { [weak self] in
            self?.onSegment?(closed, start)
        }
    }

    private static func rms(_ frames: [Float]) -> Float {
        var sum: Float = 0
        for f in frames { sum += f * f }
        return (sum / Float(frames.count)).squareRoot()
    }
}
