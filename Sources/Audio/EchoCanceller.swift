import Foundation

/// Acoustic echo canceller around the vendored Speex AEC. Feed it what the
/// speakers are playing (`playback`) and it subtracts that from mic audio
/// (`process`) before transcription, so the other side's voice never shows up
/// as "You" while the user's own voice passes through.
///
/// The hard part is that the reference comes from ScreenCaptureKit and the mic
/// from AVCaptureSession — two pipelines with independent pacing. Speex's
/// internal playback jitter-buffer never converges under that. So we do what
/// production AECs do: keep a sample-counted ring of reference audio and pair
/// every 10 ms mic frame with its explicitly-indexed reference frame
/// (speex_echo_cancellation), re-syncing whenever either stream stalls.
///
/// In-app only — cannot degrade system output or fight meeting apps.
final class EchoCanceller {
    private let sampleRate = 16_000
    private let frameSize = 160                  // 10 ms
    private let filterLength = 16_000 * 8 / 10   // 800 ms echo tail
    private let lock = NSLock()
    private var state: OpaquePointer?
    /// Residual echo suppressor: the linear AEC never nulls everything; this
    /// crushes what's left, keyed to the AEC's own echo estimate.
    private var preprocess: OpaquePointer?

    // Reference ring, sample-indexed. refTotal = samples ever written; the ring
    // holds the most recent `refCapacity` of them.
    private let refCapacity = 16_000 * 10
    private var ring: [Float]
    private var refTotal = 0
    /// Absolute ref-sample index the next mic frame will be paired with.
    /// Trails refTotal slightly; re-seeded whenever the streams drift apart.
    private var cursor = -1

    /// The mic is held back this long before pairing. ScreenCaptureKit
    /// delivers the reference LATE (capture pipelines buffer); without the
    /// hold, the reference matching a mic frame's echo hasn't been written
    /// yet and a causal filter can cancel nothing (measured 0 dB). Holding
    /// the mic guarantees the echo LAGS the reference — the only geometry a
    /// linear AEC can model. Costs 300 ms of caption latency.
    private let micDelaySamples = 16_000 * 3 / 10   // 300 ms
    /// Extra margin so the paired reference window is strictly older than the
    /// echo even at the jitter extremes.
    private let pairingLead = 160 * 2                // 20 ms
    /// Re-seed (and re-adapt) if pairing drifts this far off target.
    private let maxDrift = 16_000 / 5                // 200 ms

    private var micPending: [Float] = []
    private var micProcessed: [Float] = []
    private var active = false

    // Once-a-second attenuation telemetry: how much the AEC is actually
    // removing (pre vs post RMS) while reference audio is loud.
    private var statPreEnergy: Double = 0
    private var statPostEnergy: Double = 0
    private var statRefEnergy: Double = 0
    private var statFrames = 0

    init() {
        ring = [Float](repeating: 0, count: refCapacity)
        state = speex_echo_state_init(Int32(frameSize), Int32(filterLength))
        var rate: Int32 = 16_000
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

        preprocess = speex_preprocess_state_init(Int32(frameSize), 16_000)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE,
                             UnsafeMutableRawPointer(state))
        // Hard suppression when only the far side talks; gentle during
        // double-talk so the user's own voice survives. Denoise off — it eats
        // quiet speech.
        var denoise: Int32 = 0
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &denoise)
        var suppress: Int32 = -45
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &suppress)
        var suppressActive: Int32 = -12
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE,
                             &suppressActive)
    }

    deinit {
        if let preprocess { speex_preprocess_state_destroy(preprocess) }
        if let state { speex_echo_state_destroy(state) }
    }

    /// System-audio chunk (16 kHz mono float) — what the speakers are playing.
    func playback(_ frames: [Float]) {
        guard !frames.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        active = true
        for v in frames {
            ring[refTotal % refCapacity] = v
            refTotal += 1
        }
    }

    /// Mic chunk in → echo-cancelled mic chunk out (same cadence, 10 ms
    /// framing latency). Passthrough until reference audio has been seen.
    func process(_ frames: [Float]) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard active else { return frames }

        micPending.append(contentsOf: frames)
        var micBuf = [Int16](repeating: 0, count: frameSize)
        var refBuf = [Int16](repeating: 0, count: frameSize)
        var outBuf = [Int16](repeating: 0, count: frameSize)

        // Consume only frames older than the mic hold-back; the newest 300 ms
        // stay queued until the late reference for them has arrived.
        while micPending.count >= frameSize + micDelaySamples {
            // (Re-)seed the pairing cursor at its steady-state target; re-seed
            // + re-adapt whenever the streams drift apart.
            let target = refTotal - micDelaySamples - pairingLead
            if cursor < 0 || abs(cursor - target) > maxDrift {
                cursor = max(0, target)
                speex_echo_state_reset(state)
            }

            Self.toInt16(micPending[0..<frameSize], into: &micBuf)
            if cursor + frameSize <= refTotal {
                for i in 0..<frameSize {
                    let v = ring[(cursor + i) % refCapacity]
                    refBuf[i] = Int16(max(-1, min(1, v)) * 32767)
                }
                cursor += frameSize
            } else {
                // Reference stalled (quiet output stream) — no echo possible.
                for i in 0..<frameSize { refBuf[i] = 0 }
            }

            speex_echo_cancellation(state, micBuf, refBuf, &outBuf)
            speex_preprocess_run(preprocess, &outBuf)
            micProcessed.append(contentsOf: outBuf.map { Float($0) / 32768 })
            micPending.removeFirst(frameSize)

            for i in 0..<frameSize {
                statPreEnergy += Double(micBuf[i]) * Double(micBuf[i])
                statPostEnergy += Double(outBuf[i]) * Double(outBuf[i])
                statRefEnergy += Double(refBuf[i]) * Double(refBuf[i])
            }
            statFrames += 1
            if statFrames >= 100 {   // 1 s
                let pre = sqrt(statPreEnergy / Double(statFrames * frameSize)) / 32768
                let post = sqrt(statPostEnergy / Double(statFrames * frameSize)) / 32768
                let ref = sqrt(statRefEnergy / Double(statFrames * frameSize)) / 32768
                if ref > 0.003, pre > 1e-6 {
                    let db = 20 * log10(max(post, 1e-9) / pre)
                    EchoCanceller.statLog(String(
                        format: "aec: att=%.1fdB pre=%.4f post=%.4f ref=%.4f",
                        db, pre, post, ref))
                }
                statPreEnergy = 0; statPostEnergy = 0; statRefEnergy = 0
                statFrames = 0
            }
        }

        let n = min(frames.count, micProcessed.count)
        let out = Array(micProcessed.prefix(n))
        micProcessed.removeFirst(n)
        return out
    }

    /// Drop adaptation + buffered audio (output device switch, session end).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        speex_echo_state_reset(state)
        micPending.removeAll()
        micProcessed.removeAll()
        refTotal = 0
        cursor = -1
        active = false
    }

    private static let statLogURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Overhear", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("echogate.log")
    }()

    private static func statLog(_ s: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        guard let data = "\(stamp) \(s)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: statLogURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: statLogURL)
        }
    }

    private static func toInt16(_ x: ArraySlice<Float>, into out: inout [Int16]) {
        var i = 0
        for v in x {
            out[i] = Int16(max(-1, min(1, v)) * 32767)
            i += 1
        }
    }
}
