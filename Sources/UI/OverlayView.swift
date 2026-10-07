import SwiftUI

// MARK: - Button styles

/// Every button gets a real rectangular hitbox (not just the text glyphs) and
/// the classic "lightens on hover" behavior of a traditional app button.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    configuration.isPressed ? Color.white.opacity(0.22)
                        : hovering ? Color.white.opacity(0.14)
                        : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Transcript rows: full-width flat button that lightens on hover, like a
/// traditional list row. Click asks the AI about that line.
struct TranscriptRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    configuration.isPressed ? Color.white.opacity(0.18)
                        : hovering ? Color.white.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Filled variant for primary actions (Answer, Start Recording, Ask).
struct ProminentHoverButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(
                        configuration.isPressed ? 0.25 : hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// AppKit drag surface for the column divider. Blocks window-background
/// dragging (mouseDownCanMoveWindow = false) so resizing the split never moves
/// the panel, and reports drag deltas in stable window coordinates.
private struct SplitDragHandle: NSViewRepresentable {
    var onBegan: () -> Void
    var onMoved: (CGFloat) -> Void

    final class HandleView: NSView {
        var onBegan: (() -> Void)?
        var onMoved: ((CGFloat) -> Void)?
        private var startX: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            onMoved?(event.locationInWindow.x - startX)
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onBegan = onBegan
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
    }
}

/// Titlebar-style drag surface: any mousedown on it hands the event to the
/// window's native drag loop, so the strip moves the whole window.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        // Accept the very first click even when another app is frontmost, so
        // click-and-drag works in one motion instead of click-then-drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// The floating overlay: left column = status/controls/live transcript,
/// right column = the AI chat (answer feed + Ask bar).
struct OverlayView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var showSessions = false
    @State private var showSettings = false
    @State private var aiOnly = false
    @State private var askText = ""
    /// Bumped on every return from AI-only mode: gives the toggle row a fresh
    /// identity so AppKit rebuilds the switches (they otherwise come back
    /// rendered as solid blobs after the panel resize). State lives in
    /// AppState/AppSettings, so nothing is lost.
    @State private var toggleRefresh = 0
    /// Where the column divider sits (0…1 = left column's share). Persisted so
    /// the layout survives relaunch; 0.5 = equal columns.
    @AppStorage("splitFraction") private var splitFraction = 0.5
    @State private var dragStartFraction: Double?
    private let handleWidth: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if aiOnly {
                compactAI
            } else {
            windowControls
            if showSettings {
                settingsInline
            } else if showSessions {
                sessionsList
            } else {
                // Resizable two-column split: drag the middle divider to move
                // it; both columns start at equal width (splitFraction = 0.5).
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 0) {
                        // Left: everything live.
                        VStack(alignment: .leading, spacing: 10) {
                            header
                            controlsBar
                            Divider().opacity(0.3)
                            transcriptList
                        }
                        .frame(width: max(0, geo.size.width * splitFraction - handleWidth / 2),
                               alignment: .leading)

                        splitHandle(totalWidth: geo.size.width)

                        // Right: the AI chat.
                        VStack(alignment: .leading, spacing: 8) {
                            answerColumn
                            askBar
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            }
        }
        .padding(14)
        .frame(minWidth: aiOnly ? 340 : 880, minHeight: aiOnly ? 420 : 540)
        .background(Color(white: 0.10).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .onReceive(NotificationCenter.default.publisher(for: .overhearShowSettings)) { _ in
            showSessions = false
            showSettings = true
        }
        .onChange(of: aiOnly) { _, nowCompact in
            if !nowCompact { toggleRefresh += 1 }
        }
    }

    /// The draggable divider between the transcript and AI columns. Wide
    /// invisible hitbox around a thin line; drag moves the split, clamped so
    /// neither column collapses. AppKit-backed so the drag does NOT also move
    /// the window (the panel is movable-by-background) — a SwiftUI gesture
    /// can't opt out of that, and the two fighting made everything shake.
    private func splitHandle(totalWidth: CGFloat) -> some View {
        ZStack {
            Divider().opacity(0.3)
            SplitDragHandle(
                onBegan: { dragStartFraction = splitFraction },
                onMoved: { dx in
                    guard totalWidth > 0 else { return }
                    let f = (dragStartFraction ?? splitFraction) + dx / totalWidth
                    splitFraction = min(0.75, max(0.30, f))
                })
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
    }

    /// Custom top bar replacing the traffic-light chrome: close hides the
    /// overlay, quit exits the app.
    private var windowControls: some View {
        HStack(spacing: 8) {
            Button {
                AppDelegate.shared?.toggleOverlay()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            Spacer()
            Button {
                aiOnly = true
                showSessions = false
                showSettings = false
                AppDelegate.shared?.setOverlayCompact(true)
            } label: {
                Label("AI only", systemImage: "sparkles")
            }
            .help("Shrink to a small AI-only window — handy during meetings")
            Button {
                settings.pinMode = settings.pinMode == .pinned ? .normal : .pinned
            } label: {
                Label(settings.pinMode == .pinned ? "Pinned" : "Unpinned",
                      systemImage: settings.pinMode == .pinned ? "pin.fill" : "pin.slash")
            }
            .help(settings.pinMode == .pinned
                  ? "Always on top — click to let other windows cover it"
                  : "Coverable — click to keep always on top")
            Button {
                showSessions.toggle()
                if showSessions { showSettings = false }
            } label: {
                Label("Sessions", systemImage: "clock.arrow.circlepath")
            }
            .help("Saved transcripts — click one to continue it")
            Button {
                showSettings.toggle()
                if showSettings { showSessions = false }
            } label: {
                Label("Settings", systemImage: showSettings ? "xmark.circle" : "gearshape")
            }
            .help("Settings")
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(.secondary)
        // The strip between/around the buttons drags the window, like a
        // titlebar. Buttons sit on top and still get their clicks.
        .background(WindowDragArea())
    }

    /// Small AI-only window: back button, Answer, the chat feed, and the ask
    /// bar — for meetings where the full window covers too much.
    private var compactAI: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    aiOnly = false
                    AppDelegate.shared?.setOverlayCompact(false)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(.secondary)
                Spacer()
            }
            .background(WindowDragArea())
            answerColumn
            askBar
        }
    }

    /// Whether an answer is being generated (or queued) right now.
    private var aiBusy: Bool { state.isAnswering || state.answerPending }

    /// Type a question directly to the AI; it answers with the last 10
    /// transcript lines as context. The send arrow becomes a stop square
    /// while the AI is answering.
    private var askBar: some View {
        HStack(spacing: 6) {
            TextField("Ask AI…", text: $askText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit { submitAsk() }
            Button {
                if aiBusy {
                    state.cancelAnswer()
                } else {
                    submitAsk()
                }
            } label: {
                Image(systemName: aiBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ProminentHoverButtonStyle(
                tint: aiBusy ? Color.red.opacity(0.85) : .accentColor))
            .disabled(!aiBusy
                      && askText.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(aiBusy ? "Stop the AI" : "Send")
        }
    }

    private func submitAsk() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askText = ""
        state.ask(q)
    }

    // MARK: - Sessions

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    state.newSession()
                    showSessions = false
                } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(HoverButtonStyle())
            }
            if state.sessions.sessions.isEmpty {
                Text("No sessions yet — start listening and the transcript "
                     + "saves automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.sessions.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body).lineLimit(1)
                Text("\(session.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                     + " · \(session.utterances.count) lines")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.sessions.currentID == session.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }
            Button {
                state.sessions.delete(session)
            } label: { Image(systemName: "trash") }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(.secondary)
                .help("Delete this session")
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            state.openSession(session)
            showSessions = false
        }
    }

    // MARK: - Settings (inline)

    /// The full settings UI rendered inside the overlay panel itself, instead of
    /// a separate macOS Settings window.
    private var settingsInline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title3.weight(.semibold))

                settingsGroup("Overlay") {
                    HStack {
                        Text("Show / hide hotkey").font(.body)
                        Spacer()
                        ShortcutField(shortcut: $settings.toggleShortcut)
                            .frame(width: 130, height: 24)
                    }
                    Picker("Window pinning", selection: $settings.pinMode) {
                        ForEach(PinMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .font(.body)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opacity: \(Int(settings.opacity * 100))%").font(.body)
                        Slider(value: $settings.opacity, in: 0.3...1.0)
                    }
                }

                settingsGroup("Vision") {
                    Picker("Capture", selection: $settings.captureTarget) {
                        ForEach(CaptureTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .font(.body)
                    Text("Used when “Use screen” is on — a live screenshot is "
                         + "attached so a vision model can read slides or code.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !state.selectedModelIsVisionCapable {
                        Label("Current model likely can't read images. Pull a "
                              + "vision model like llava or qwen2.5vl.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                settingsGroup("Permissions") {
                    settingsPermissionRow("Microphone", PermissionsService.microphone) {
                        PermissionsService.openMicrophoneSettings()
                    }
                    settingsPermissionRow("Screen Recording", PermissionsService.screenRecording) {
                        PermissionsService.requestScreenRecording()
                        PermissionsService.openScreenRecordingSettings()
                    }
                    HStack {
                        Text("Mic mode").font(.body)
                        Spacer()
                        Label("Voice Isolation", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    }
                    Text("Voice Isolation strips background noise and speaker "
                         + "bleed on the Neural Engine. Echo handling is automatic.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsGroup("Ollama") {
                    HStack {
                        Text("Status").font(.body)
                        Spacer()
                        if state.ollamaReachable {
                            Label("Running", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).labelStyle(.titleAndIcon)
                        } else {
                            Label("Not reachable", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.callout)
                    Button("Recheck") { Task { await state.refreshModels() } }
                        .buttonStyle(HoverButtonStyle())
                    if state.availableModels.isEmpty {
                        Label("No models found — run `ollama pull qwen2.5:7b`.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("\(state.availableModels.count) model(s) installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func settingsGroup<Content: View>(_ title: String,
                                              @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingsPermissionRow(_ name: String, _ st: PermissionsService.State,
                                       action: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.body)
            Spacer()
            switch st {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
            default:
                Button("Grant…", action: action).buttonStyle(HoverButtonStyle())
            }
        }
    }

    // MARK: - Left column

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isListening ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(action: state.toggleListening) {
                HStack(spacing: 6) {
                    Text(state.isListening ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: state.isListening ? "stop.fill" : "waveform")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(ProminentHoverButtonStyle(
                tint: state.isListening ? Color.red.opacity(0.85) : .accentColor))
            .help(state.isListening ? "Stop listening" : "Start listening")
        }
    }

    /// Model picker + auto/vision toggles.
    private var controlsBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $state.selectedModel) {
                    if state.availableModels.isEmpty {
                        Text(state.selectedModel).tag(state.selectedModel)
                    }
                    ForEach(state.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Button {
                    Task { await state.refreshModels() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HoverButtonStyle())
                    .help("Reload installed models")
            }
            HStack(spacing: 12) {
                Toggle(isOn: $state.autoMode) {
                    Text("Auto-answer").font(.callout)
                }
                .toggleStyle(.switch).controlSize(.mini)
                Toggle(isOn: $state.ocrMode) {
                    Text("OCR").font(.callout)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help("Read the screen as text (Apple OCR, ~free) and give it to "
                      + "the model — no screenshots, no vision cost")
                Toggle(isOn: $state.useScreen) {
                    Text("Use screen").font(.callout)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(state.ocrMode)
                .help(state.ocrMode
                      ? "Off while OCR mode is on"
                      : "Attach a live screenshot to answers (needs a vision model)")
                Toggle(isOn: $settings.invisible) {
                    Text("Invisible").font(.callout)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help(settings.invisible
                      ? "Hidden from screen shares, recordings, screenshots — click to make it visible"
                      : "Visible in screen shares and recordings — click to hide it")
                Spacer()
            }
            .id("toggles-\(toggleRefresh)")
            if state.useScreen && !state.selectedModelIsVisionCapable {
                Text("Selected model may not read images — pick a vision model (llava, qwen2.5vl…)")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !state.ollamaReachable {
                Text("Ollama not running — start `ollama serve`")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Right column (AI chat)

    /// The AI's answer feed: every completed answer labeled with the question it
    /// replied to, plus the currently-streaming one at the bottom.
    private var answerColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                if state.answerPending {
                    Text("waiting for question to finish…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if state.isAnswering {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if state.answerHistory.isEmpty && state.answer.isEmpty
                            && !state.isAnswering && state.answerError == nil {
                            Text("Answers appear here.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
                        }
                        ForEach(state.answerHistory) { record in
                            answerCell(question: record.question,
                                       text: record.text)
                                .id(record.id)
                        }
                        if state.isAnswering || !state.answer.isEmpty {
                            answerCell(question: state.currentQuestion,
                                       text: state.answer)
                                .id("live-answer")
                        }
                        if let err = state.answerError {
                            Text(err).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: state.answer) { _, _ in
                    proxy.scrollTo("live-answer", anchor: .bottom)
                }
                .onChange(of: state.answerHistory.count) { _, _ in
                    if let last = state.answerHistory.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func answerCell(question: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                if let question, !question.isEmpty {
                    Text("Replying to: \(question)")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if !text.isEmpty {
                    CopyButton(text: text)
                }
            }
            if !text.isEmpty {
                MathAnswerView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Copies the full answer (meeting summaries included) to the clipboard;
    /// flashes a checkmark as confirmation.
    private struct CopyButton: View {
        let text: String
        @State private var copied = false

        var body: some View {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Copy to clipboard")
        }
    }

    private var statusText: String {
        switch state.status {
        case .idle: return "Idle"
        case .downloadingModel(let p): return "Downloading model \(Int(p * 100))%"
        case .needsMicPermission: return "Microphone permission needed"
        case .listening: return "Listening"
        case .error(let m): return m
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Follow the newest content: a live partial if present, else last final.
        if let partial = activePartials.last {
            withAnimation { proxy.scrollTo("partial-\(partial.0.rawValue)", anchor: .bottom) }
        } else if let last = state.transcript.utterances.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var activePartials: [(Speaker, String)] {
        state.transcript.partials
            .filter { !$0.value.isEmpty }
            .map { ($0.key, $0.value) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    @ViewBuilder
    private func captionRow(speaker: Speaker, text: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(speaker.label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(speaker == .me ? .blue : .orange)
                if live {
                    Text("live").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text(text).font(.body)
                .foregroundStyle(live ? .secondary : .primary)
                .italic(live)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // Each finalized line is a button: click = ask the AI about
                    // that exact line (context: 4 lines above + 2 below).
                    ForEach(state.transcript.utterances) { u in
                        Button { state.answerUtterance(u) } label: {
                            captionRow(speaker: u.speaker, text: u.text, live: false)
                        }
                        .buttonStyle(TranscriptRowButtonStyle())
                        .help("Ask the AI about this line")
                        .id(u.id)
                    }
                    // Live (non-final) captions, dimmed, below the finalized lines.
                    ForEach(activePartials, id: \.0) { speaker, text in
                        captionRow(speaker: speaker, text: text, live: true)
                            .id("partial-\(speaker.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: state.transcript.utterances.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: state.transcript.partials) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }
}
