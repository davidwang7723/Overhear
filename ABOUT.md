# What is Overhear?

**Overhear is a fully offline, local-only live answer assistant for macOS.** It
listens to a meeting, interview, or class, optionally watches your screen, and
answers questions in real time — using only models running on your own Mac.
Nothing is ever sent to the cloud; no audio, text, or screen content leaves the
device.

## What it does

- **Listens to both sides of a conversation.** Your voice comes from the
  built-in microphone; the other party's voice is captured from system audio
  (Zoom, Meet, a video, etc.). Lines are tagged **You** vs **Them**.
- **Transcribes live**, showing streaming captions as people speak.
- **Answers questions** — automatically when it hears a question, when you click
  any transcript line, or when you type into the Ask box. Answers stream in and
  render Markdown and LaTeX math.
- **Watches your screen on demand.** Two modes: OCR (reads on-screen text with
  Apple's Vision framework — works with any model, no image sent to the LLM) or
  Vision (attaches a screenshot to a multimodal model). If a question you ask is
  actually a question shown on screen — a quiz, slide, or exam item — it answers
  that exact on-screen question.
- **Stays out of the way.** The overlay is a floating panel that follows you
  across desktops, can be pinned always-on-top, and is excluded from screen
  shares and recordings — invisible to anyone you're screen-sharing with.
- **Remembers sessions.** Every transcript and answer is saved; you can reopen a
  past session and continue it, and generate a meeting summary on stop.
- **AI-only compact mode** shrinks the window to just the answer feed for use
  during a call.

## How it works (all on-device)

| Piece | Technology |
|-------|-----------|
| Speech-to-text | Apple **SpeechAnalyzer / SpeechTranscriber** (Neural Engine) |
| Language model | **Ollama** on `127.0.0.1:11434` — one multimodal model does classification, text answers, and vision |
| Microphone | `AVCaptureSession`, pinned to the built-in mic |
| System audio + screenshots | **ScreenCaptureKit** |
| Screen text | Apple **Vision** framework OCR |
| Echo/bleed control | Vendored **Speex** acoustic echo canceller + a text-overlap bleed filter, so the other side's voice playing from your speakers doesn't get transcribed as yours |
| UI | SwiftUI in a non-activating `NSPanel` overlay |

## Design principles

- **Local-only, always.** The sole network calls are to a local Ollama server on
  `127.0.0.1`. There is no telemetry, no account, no remote API.
- **Single-model.** One Ollama model handles everything, so only the system
  speech model and one LLM are ever loaded.
- **Invisible by default.** The overlay never appears in a screen share and
  never steals keyboard focus from your meeting app.

## Best results

Use **headphones**. With speakers, the other party's audio physically re-enters
your microphone; the built-in echo cancellation and bleed filter reduce this but
can't fully remove it during simultaneous speech — the same reason every meeting
assistant recommends headphones.
