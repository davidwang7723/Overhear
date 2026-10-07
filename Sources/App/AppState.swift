import Foundation
import AVFoundation
import AppKit
import Combine

/// Top-level coordinator. Owns the capture → transcription → store pipeline
/// and the state the UI observes.
@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloadingModel(Double)
        case needsMicPermission
        case listening
        case error(String)
    }

    /// Shared instance so the menu bar scene and the overlay panel observe the
    /// same state.
    static let shared = AppState()

    @Published private(set) var status: Status = .idle
    @Published var isListening = false

    let transcript = TranscriptStore()
    let sessions = SessionStore()

    /// Whether system-audio capture (their voice) is active. Falls back to
    /// mic-only if screen-recording permission is denied.
    @Published private(set) var systemAudioActive = false

    // Answer state (M3).
    @Published private(set) var answer = ""
    @Published private(set) var isAnswering = false
    @Published private(set) var answerPending = false
    @Published var answerError: String?
    /// The question the in-flight answer is replying to (shown as its label).
    @Published private(set) var currentQuestion: String?
    /// Completed answers for this session, oldest first.
    @Published private(set) var answerHistory: [AnswerRecord] = []

    // Models (M4) — populated from the local Ollama install.
    // One multimodal model does everything: question classify, text answers, and
    // (when "Use screen" is on) vision. A vision-capable model handles text-only
    // fine, so we only ever load ONE Ollama model + whisper.
    @Published private(set) var availableModels: [String] = []
    @Published var selectedModel =
        UserDefaults.standard.string(forKey: "selectedModel") ?? "qwen2.5:7b" {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
            updateVisionCapability()
        }
    }
    @Published private(set) var ollamaReachable = true
    /// Whether the selected model can accept images — from Ollama's reported
    /// capabilities, not a name guess.
    @Published private(set) var selectedModelIsVisionCapable = false

    private var visionCapabilityCache: [String: Bool] = [:]

    // Auto mode (M4) + live vision. All persisted so the toggles come back
    // exactly as the user left them.
    @Published var autoMode = UserDefaults.standard.bool(forKey: "autoMode") {
        didSet { UserDefaults.standard.set(autoMode, forKey: "autoMode") }
    }
    @Published var useScreen = UserDefaults.standard.bool(forKey: "useScreen") {
        didSet {
            UserDefaults.standard.set(useScreen, forKey: "useScreen")
            updateScreenSummarizer()
        }
    }
    /// OCR mode: no screenshots to the model, ever. At answer time the screen's
    /// text is extracted (Apple OCR, Neural Engine) and handed to the LLM as
    /// context. Mutually exclusive with `useScreen` — turning this on forces
    /// vision off.
    @Published var ocrMode = UserDefaults.standard.bool(forKey: "ocrMode") {
        didSet {
            UserDefaults.standard.set(ocrMode, forKey: "ocrMode")
            if ocrMode { useScreen = false }
            updateScreenSummarizer()
        }
    }

    /// Rolling text summaries of the screen, captured every `summaryInterval`.
    /// Only these summaries (never the raw periodic screenshots) are given to the
    /// model as context; the single current screenshot is attached only at answer
    /// time.
    @Published private(set) var screenSummaries: [String] = []
    private var summaryTask: Task<Void, Never>?
    /// OCR tick cadence: every 30s normally; after an answer, `ocrPausedUntil`
    /// holds it off for 60s, then this cadence resumes.
    private let summaryInterval: Duration = .seconds(30)
    private let maxSummaries = 8
    private var lastSummaryHash: Int?
    /// First capture after an answer starts comes exactly this much later.
    private let postAnswerDelay: Duration = .seconds(60)

    /// Delay after a manual trigger so an in-progress utterance can finish
    /// transcribing before we answer.
    private let manualAnswerDelay: Duration = .seconds(2)
    /// Manual answers focus on the latest "them" question no older than this.
    private let manualQuestionMaxAge: TimeInterval = 30

    private let capture = AudioCaptureService()
    private let systemCapture = SystemAudioCaptureService()
    private let screen = ScreenCaptureService()
    /// Software AEC (vendored Speex): subtracts what the speakers play from
    /// the mic BEFORE segmentation/transcription, so the other side's voice
    /// never reaches the transcript as "You". In-app only — cannot degrade
    /// system output or fight meeting apps the way Apple's VPIO did. Backstop:
    /// isCrossBleed text matching catches whatever leaks through.
    private let aec = EchoCanceller()
    /// Output device switches (headphones ↔ speakers) mid-session: the system
    /// audio tap follows the output path, so it's restarted on the new device.
    private let outputWatcher = OutputDeviceWatcher()
    private var outputRestartTask: Task<Void, Never>?
    // Separate ASR engines: finals never wait behind the frequent live
    // partial passes, so finalized captions appear immediately.
    private let engineFinal = TranscriptionEngine()
    private let enginePartial = TranscriptionEngine()
    private let answers = AnswerEngine()
    private let ollama = OllamaClient()
    private var pendingAnswerTask: Task<Void, Never>?
    private var partialInFlight: Set<Speaker> = []
    /// Bumped per speaker whenever a segment finalizes, so in-flight partial
    /// transcriptions from an already-closed segment are discarded instead of
    /// re-planting a stale "ghost" caption.
    private var partialGeneration: [Speaker: Int] = [:]
    private var lastAnsweredID: UUID?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // TranscriptStore is a nested ObservableObject: SwiftUI does NOT observe
        // it through `state.transcript`, so forward its changes or the overlay
        // only refreshes when AppState itself publishes (e.g. on Stop).
        transcript.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        capture.onSegment = { [weak self] frames, start in
            self?.handleSegment(frames, start: start, speaker: .me)
        }
        capture.onPartial = { [weak self] frames, _ in
            self?.handlePartial(frames, speaker: .me)
        }
        systemCapture.onSegment = { [weak self] frames, start in
            self?.handleSegment(frames, start: start, speaker: .them)
        }
        systemCapture.onPartial = { [weak self] frames, _ in
            self?.handlePartial(frames, speaker: .them)
        }
        systemCapture.onRawAudio = { [aec] frames in
            aec.playback(frames)
        }
        capture.preprocess = { [aec] frames in
            aec.process(frames)
        }
        // Auto-adapt when the user switches sound output (e.g. Bluetooth
        // headphones → Mac speakers) mid-session: restart the system-audio tap
        // on the new device so transcription never stops. Mic capture is
        // untouched — it's pinned to the built-in mic regardless of routing.
        outputWatcher.onChange = { [weak self] in
            Task { @MainActor in self?.handleOutputDeviceChange() }
        }
        outputWatcher.start()
        Task { await refreshModels() }
    }

    /// Debounced (device switches fire several notifications back-to-back).
    private func handleOutputDeviceChange() {
        guard isListening else { return }
        outputRestartTask?.cancel()
        outputRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.systemCapture.stop()
            // New output path = new echo characteristics; re-adapt from scratch.
            self.aec.reset()
            do {
                try await self.systemCapture.start()
                self.systemAudioActive = true
            } catch {
                self.systemAudioActive = false
            }
        }
    }

    // MARK: - Models

    func refreshModels() async {
        ollamaReachable = await ollama.isReachable()
        // Drop embedding-only models — they can't chat.
        let models = await ollama.listModels().filter {
            !$0.lowercased().contains("embed")
        }
        availableModels = models
        if !models.contains(selectedModel), let first = models.first {
            selectedModel = first
        }
        updateVisionCapability()
    }

    /// Refresh whether the selected model can see images (cached per model).
    private func updateVisionCapability() {
        if let cached = visionCapabilityCache[selectedModel] {
            selectedModelIsVisionCapable = cached
            return
        }
        selectedModelIsVisionCapable = false
        let model = selectedModel
        Task { [weak self] in
            guard let self else { return }
            let isVision = await ollama.capabilities(model: model).contains("vision")
            visionCapabilityCache[model] = isVision
            if selectedModel == model {
                selectedModelIsVisionCapable = isVision
                updateScreenSummarizer()
            }
        }
    }

    // MARK: - Screen capture & analysis loop

    private func updateScreenSummarizer() {
        // The rolling context loop is OCR-based either way, so it runs for both
        // vision mode (useScreen) and OCR mode.
        if useScreen || ocrMode, isListening {
            if summaryTask == nil { startSummaryLoop() }
        } else {
            stopSummaryLoop()
            if !useScreen && !ocrMode { screenSummaries.removeAll() }
        }
    }

    /// (Re)start the capture loop. `firstDelay` is the wait before the first
    /// capture (60s after an answer starts, 30s otherwise); every capture after
    /// that follows the normal 30s cadence.
    private func startSummaryLoop(firstDelay: Duration? = nil) {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            guard let self else { return }
            var delay = firstDelay ?? summaryInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
                await self.summaryTick()
                delay = self.summaryInterval
            }
        }
    }

    private func stopSummaryLoop() {
        summaryTask?.cancel()
        summaryTask = nil
    }

    /// Periodically OCR the screen (Neural Engine, ~free) and keep the text as
    /// context. No vision-LLM pass here — that only happens at answer time.
    /// Skips unchanged screens.
    private func summaryTick() async {
        guard useScreen || ocrMode, isListening, !isAnswering, !answerPending,
              let result = await screen.captureText() else { return }
        if result.hash == lastSummaryHash || result.text.isEmpty { return }
        lastSummaryHash = result.hash
        // Cap each capture's text so context stays lean.
        let snippet = String(result.text.prefix(1500))
        screenSummaries.append(snippet)
        if screenSummaries.count > maxSummaries {
            screenSummaries.removeFirst(screenSummaries.count - maxSummaries)
        }
    }

    // MARK: - Lifecycle

    func toggleListening() {
        if isListening {
            stop(summarize: true)   // user ended the meeting → summarize it
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isListening else { return }

        // 1. Speech models (Parakeet downloads once on first run).
        if await !engineFinal.isLoaded {
            status = .downloadingModel(0)
            guard await engineFinal.load(), await enginePartial.load() else {
                status = .error("Speech model download/load failed — check network and retry")
                return
            }
        }

        // 2. Mic permission
        guard await requestMicPermission() else {
            status = .needsMicPermission
            return
        }

        // 3. Mic capture — always the raw built-in mic (see AudioCaptureService).
        do {
            try capture.start()
            isListening = true
            status = .listening
        } catch {
            status = .error("Audio start failed: \(error.localizedDescription)")
            return
        }

        // 3b. Voice Isolation SABOTAGES the echo canceller: its neural
        // processing rewrites the mic signal nonlinearly, so the linear AEC
        // can no longer subtract the speaker reference (measured 0 dB
        // attenuation with VI on). Warn once per run when it's active.
        if !voiceIsolationNudged, MicModeService.isVoiceIsolationActive {
            voiceIsolationNudged = true
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Turn OFF Voice Isolation"
            alert.informativeText = "Voice Isolation scrambles the mic signal "
                + "and disables Overhear's echo cancellation — speaker audio "
                + "will leak into your transcript. Click Open, then choose "
                + "Mic Mode ▸ Standard."
            alert.addButton(withTitle: "Open Mic Mode Picker")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                MicModeService.showPicker()
            }
        }

        // 4. System-audio capture (optional — degrade to mic-only on failure).
        // Preflight quietly: when the screen-recording grant is already there,
        // this never prompts; when it's missing, offer the reset flow at most
        // once per app run instead of nagging on every Start.
        do {
            try await systemCapture.start()
            systemAudioActive = true
        } catch {
            systemAudioActive = false
            status = .error("Mic only — system audio unavailable: \(error.localizedDescription)")
            if !offeredPermissionReset {
                offeredPermissionReset = true
                offerPermissionReset(error.localizedDescription)
            }
        }

        // 5. Refresh model list; start summary loop if applicable.
        await refreshModels()
        updateScreenSummarizer()
    }

    /// One Voice Isolation nudge per app run (see start()).
    private var voiceIsolationNudged = false
    /// The permission-reset dialog shows at most once per app run.
    private var offeredPermissionReset = false

    /// System-audio capture failed (usually a declined/stuck TCC grant): offer
    /// to wipe Overhear's permission records so macOS asks fresh. tccutil needs
    /// the app relaunched for the new prompts, so we quit and auto-reopen.
    private func offerPermissionReset(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "System audio capture unavailable"
        alert.informativeText = "Only your mic is being transcribed — the other "
            + "side's audio (and echo filtering) needs Screen & System Audio "
            + "Recording.\n\nReason: \(reason)\n\nReset Permissions wipes "
            + "Overhear's mic and screen-recording grants so you can re-enable "
            + "them fresh in System Settings."
        alert.addButton(withTitle: "Reset Permissions")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.davidwang7723.Overhear"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "All", bundleID]
        try? reset.run()
        reset.waitUntilExit()

        // Walk the user to the re-grant. Overhear stays running — when the
        // grants are flipped, System Settings itself asks to quit & reopen the
        // app, which is the right moment.
        let done = NSAlert()
        done.alertStyle = .informational
        done.messageText = "Now re-enable the permissions"
        done.informativeText = "Overhear's permission records were wiped.\n\nIn "
            + "System Settings ▸ Privacy & Security, turn ON both:\n"
            + "  •  Microphone\n  •  Screen & System Audio Recording\n\n"
            + "System Settings will then ask you to quit and reopen Overhear."
        done.addButton(withTitle: "Open System Settings")
        done.addButton(withTitle: "Later")
        if done.runModal() == .alertFirstButtonReturn {
            // Deep-link straight to the Screen & System Audio Recording pane
            // (the mic pane is one click away in the same list).
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func stop(summarize: Bool = false) {
        capture.stop()
        systemCapture.stop()
        aec.reset()
        stopSummaryLoop()
        systemAudioActive = false
        isListening = false
        status = .idle
        transcript.setPartial("", for: .me)
        transcript.setPartial("", for: .them)
        if summarize { generateMeetingSummary() }
    }

    /// After the user ends a meeting: have the LLM summarize the transcript and
    /// drop the summary into the answer feed (and the saved session).
    private func generateMeetingSummary() {
        guard transcript.utterances.count >= 4 else { return }
        let full = transcript.window(200, includePartials: false)
        let model = selectedModel
        isAnswering = true
        Task { [weak self] in
            guard let self else { return }
            let prompt = """
            Summarize this meeting/class transcript: main topics, key points, \
            decisions, action items, and questions raised. Use short bullets. \
            "Them" is the other party; "You" is the user.

            Transcript:
            \(full)
            """
            let text = await ollama.chatComplete(
                model: model,
                messages: [.init(role: "user", content: prompt)])
            isAnswering = false
            guard !text.isEmpty else { return }
            answerHistory.append(AnswerRecord(question: "Meeting summary", text: text))
            sessions.autosave(transcript.utterances, answers: answerHistory)
        }
    }

    // MARK: - Answering

    /// Manual trigger (button / hotkey). Waits `manualAnswerDelay` for the
    /// current utterance to finalize, then answers — focused on the latest
    /// recent "them" question so the model doesn't dig up something old.
    func requestAnswer() {
        pendingAnswerTask?.cancel()
        answers.cancel()
        answer = ""
        answerError = nil
        answerPending = true
        pendingAnswerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: manualAnswerDelay)
            if Task.isCancelled { return }
            self.answerPending = false
            if let u = self.transcript.latest(from: .them),
               Date().timeIntervalSince(u.end) < self.manualQuestionMaxAge {
                self.runAnswer(question: u.text, contextEndingAt: u.id)
            } else {
                self.runAnswer()
            }
        }
    }

    /// Typed question from the user: answered with the last 10 transcript lines
    /// as context.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        pendingAnswerTask?.cancel()
        answers.cancel()
        answerPending = false
        answer = ""
        answerError = nil
        runAnswer(question: q, windowCount: 10)
    }

    /// Click on a transcript row: answer that exact line, with the 4 lines
    /// above and 2 below it as context.
    func answerUtterance(_ u: Utterance) {
        pendingAnswerTask?.cancel()
        answers.cancel()
        answerPending = false
        answer = ""
        answerError = nil
        runAnswer(question: u.text,
                  window: transcript.window(around: u.id, before: 4, after: 2),
                  clicked: true)
    }

    func cancelAnswer() {
        pendingAnswerTask?.cancel()
        answers.cancel()
        answerPending = false
        isAnswering = false
    }

    /// `contextEndingAt`: the question utterance's id — the model sees that
    /// question plus the 5 utterances before it. Nil (typed ask / fallback)
    /// uses the transcript tail of `windowCount` lines.
    private func runAnswer(question: String? = nil,
                           contextEndingAt contextID: UUID? = nil,
                           windowCount: Int = 5,
                           window explicitWindow: String? = nil,
                           clicked: Bool = false) {
        let window = explicitWindow
            ?? (contextID != nil
                ? transcript.window(endingAt: contextID, prior: windowCount)
                : transcript.window(windowCount))
        guard !window.isEmpty else { return }
        currentQuestion = question ?? transcript.latest(from: .them)?.text
        // Answer starting: TERMINATE any in-flight capture/analysis — the GPU
        // belongs to the answer now. Restart the loop with a 60s first delay
        // (measured from answer start), then the normal 30s cadence.
        stopSummaryLoop()
        if useScreen || ocrMode, isListening {
            startSummaryLoop(firstDelay: postAnswerDelay)
        }
        answer = ""
        answerError = nil
        isAnswering = true
        let summaries = screenSummaries
        Task { [weak self] in
            guard let self else { return }
            // Vision mode: attach the single CURRENT screenshot (plus rolling
            // text context). OCR mode: no image ever — fresh screen text from
            // Apple OCR is the model's eyes. Old periodic images are never sent.
            NSLog("Overhear runAnswer: ocrMode=\(ocrMode) useScreen=\(useScreen) q=\(question ?? "nil")")
            var image: String? = nil
            var context: String? = nil
            if useScreen {
                image = await screen.captureBase64(target: .fullDisplay)
                if !summaries.isEmpty {
                    context = summaries.map { "- \($0)" }.joined(separator: "\n")
                }
            } else if ocrMode {
                var parts: [String] = []
                let fresh = await screen.captureText()
                NSLog("Overhear runAnswer OCR: got \(fresh?.text.count ?? -1) chars")
                if let fresh, !fresh.text.isEmpty {
                    parts.append("[Current screen text]\n" + String(fresh.text.prefix(2000)))
                }
                if !summaries.isEmpty {
                    parts.append("[Earlier screens]\n"
                                 + summaries.map { "- \($0)" }.joined(separator: "\n"))
                }
                if !parts.isEmpty { context = parts.joined(separator: "\n\n") }
            }
            answers.model = selectedModel
            // Last few finished answers as chat memory, so follow-ups
            // ("explain that more") resolve against what the AI already said.
            let history = answerHistory.suffix(3).map {
                (question: $0.question, answer: $0.text)
            }
            answers.generate(
                transcriptWindow: window,
                focusQuestion: question,
                clickedLine: clicked,
                history: Array(history),
                screenContext: context,
                imageBase64: image,
                onToken: { [weak self] piece in self?.answer += piece },
                onDone: { [weak self] err in
                    guard let self else { return }
                    self.isAnswering = false
                    if let err { self.answerError = err.localizedDescription }
                    // Archive the completed answer under its question.
                    if !self.answer.isEmpty {
                        self.answerHistory.append(AnswerRecord(
                            question: self.currentQuestion, text: self.answer))
                        self.answer = ""
                        self.currentQuestion = nil
                        self.sessions.autosave(self.transcript.utterances,
                                               answers: self.answerHistory)
                    }
                })
        }
    }

    // MARK: - Auto mode (M4)

    /// Event-driven: fires the moment an utterance finalizes containing a
    /// question mark — from THEM or from the user asking aloud. No polling, so
    /// it can never resurrect an old question.
    private func maybeAutoAnswer(_ utterance: Utterance) {
        guard autoMode, isListening, !isAnswering, !answerPending,
              utterance.text.contains("?"),
              utterance.id != lastAnsweredID else { return }
        lastAnsweredID = utterance.id
        answer = ""
        answerError = nil
        runAnswer(question: utterance.text, contextEndingAt: utterance.id)
    }

    // MARK: - Pipeline

    private func handleSegment(_ frames: [Float], start: Date, speaker: Speaker) {
        // Segment closed → its live partial is obsolete; invalidate in-flight ones.
        partialGeneration[speaker, default: 0] += 1
        transcript.setPartial("", for: speaker)
        Task {
            let text = Self.cleanTranscript(await engineFinal.transcribe(frames))
            guard !text.isEmpty else { return }
            // Bleed check AFTER transcription: same words as the other channel
            // just said = that channel through the air, not new speech.
            if isCrossBleed(text, speaker: speaker) { return }
            // The mic often finalizes BEFORE the system channel's text lands,
            // so a bleed line can pass its first check against nothing. When
            // system audio is live, hold "You" lines briefly and re-check
            // against the updated "Them" text.
            if speaker == .me, systemAudioActive {
                try? await Task.sleep(for: .milliseconds(2500))
                if isCrossBleed(text, speaker: speaker) { return }
            }
            let utterance = Utterance(speaker: speaker, text: text,
                                      start: start, end: Date(), isFinal: true)
            transcript.append(utterance)
            sessions.autosave(transcript.utterances, answers: answerHistory)
            maybeAutoAnswer(utterance)
        }
    }

    /// TEXT-level bleed screen. True when most of `text`'s words already appear
    /// in the OTHER channel's recent lines: mic picking the teacher up from the
    /// speakers, or system audio carrying the user's meeting echo. Content
    /// matching is immune to Voice Isolation / codecs, which broke every
    /// waveform approach. Decisions log to ~/Library/Logs/Overhear/echogate.log.
    private func isCrossBleed(_ text: String, speaker: Speaker) -> Bool {
        let other: Speaker = speaker == .me ? .them : .me
        let now = Date()
        var otherText = transcript.utterances
            .filter { $0.speaker == other && now.timeIntervalSince($0.end) < 12 }
            .map(\.text).joined(separator: " ")
        if let partial = transcript.partials[other] { otherText += " " + partial }

        let words = Self.matchTokens(text)
        guard !words.isEmpty else { return false }
        let otherWords = Self.matchTokens(otherText)
        guard !otherWords.isEmpty else { return false }

        // Real bleed is a near-verbatim COPY: same words in the same ORDER.
        // The user's own speech reuses common words ("how do you…") in a new
        // order — plain word-set overlap false-flagged those, so consecutive
        // word pairs are the primary signal.
        let otherSet = Set(otherWords)
        let unigram = Float(words.filter(otherSet.contains).count) / Float(words.count)
        var bigram: Float = 0
        if words.count >= 2 {
            let otherPairs = Set(zip(otherWords, otherWords.dropFirst())
                .map { "\($0) \($1)" })
            let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
            bigram = Float(pairs.filter(otherPairs.contains).count) / Float(pairs.count)
        }
        let bleed = words.count >= 2
            ? (bigram >= 0.5 || unigram >= 0.9)
            : unigram >= 1.0
        Self.gateLog(String(format: "%@: bigram=%.2f unigram=%.2f words=%d -> %@  \"%@\"",
                            speaker == .me ? "mic-bleed" : "mirror",
                            bigram, unigram, words.count, bleed ? "DROP" : "keep",
                            String(text.prefix(60))))
        return bleed
    }

    /// Lowercased alphanumeric words, 2+ chars (drops "a"/"I" noise).
    private static func matchTokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static let gateLogURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Overhear", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("echogate.log")
    }()

    private static func gateLog(_ s: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        guard let data = "\(stamp) \(s)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: gateLogURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: gateLogURL)
        }
    }

    // MARK: - Sessions

    /// Continue a saved session: its transcript and answer history load, and
    /// new speech appends.
    func openSession(_ session: Session) {
        if isListening { stop() }
        cancelAnswer()
        sessions.open(session)
        transcript.load(session.utterances)
        answerHistory = session.answers ?? []
        answer = ""
        answerError = nil
        currentQuestion = nil
    }

    /// Clear the deck; the next utterance starts a fresh session.
    func newSession() {
        if isListening { stop() }
        cancelAnswer()
        sessions.startNew()
        transcript.clear()
        answerHistory = []
        answer = ""
        answerError = nil
        currentQuestion = nil
    }

    /// Live (non-final) caption. Skips if a partial for this speaker is already
    /// transcribing, so partials never pile up on the whisper actor.
    private func handlePartial(_ frames: [Float], speaker: Speaker) {
        guard !partialInFlight.contains(speaker) else { return }
        partialInFlight.insert(speaker)
        let gen = partialGeneration[speaker, default: 0]
        Task {
            let text = Self.cleanTranscript(await enginePartial.transcribe(frames))
            partialInFlight.remove(speaker)
            // Drop the result if its segment already finalized while we worked.
            guard !text.isEmpty,
                  partialGeneration[speaker, default: 0] == gen else { return }
            // Live captions shouldn't flash speaker bleed either.
            if isCrossBleed(text, speaker: speaker) { return }
            transcript.setPartial(text, for: speaker)
        }
    }

    /// Strip whisper's non-speech annotations — on music/noise it emits things
    /// like "[Music]", "(silence)", "[BLANK_AUDIO]", "♪" that flash in and out
    /// of the captions.
    private static func cleanTranscript(_ text: String) -> String {
        var t = text
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)"] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "♪", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
