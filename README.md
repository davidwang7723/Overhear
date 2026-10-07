# Overhear

Local-only live answer assistant for macOS. It listens to a meeting, interview,
or class, optionally watches your screen, and answers questions in real time —
**fully offline**. Nothing leaves your Mac: no cloud, no account, no telemetry.
The only network calls are to a local Ollama server on `127.0.0.1`.

See [ABOUT.md](ABOUT.md) for a feature-level overview.

## Download

**[Download the latest release →](https://github.com/davidwang7723/Overhear/releases/latest)**

Grab `Overhear_vX.Y.Z.dmg`, drag **Overhear** to Applications. The app is ad-hoc
signed (not notarized), so on first launch **right-click the app → Open → Open**
(or System Settings ▸ Privacy & Security ▸ **Open Anyway**). You'll also need
[Ollama](https://ollama.com) running locally. Requires macOS 26+, Apple Silicon.

Prefer to build it yourself? See [Build & run](#build--run-dev) below.

## How it works

| Piece | Technology |
|-------|-----------|
| Speech-to-text | Apple **SpeechAnalyzer / SpeechTranscriber** (on-device, Neural Engine). `en_US` assets auto-download once from Apple. |
| Language model | **Ollama** on `127.0.0.1:11434` — one multimodal model does classification, text answers, and vision |
| Microphone | `AVCaptureSession`, pinned to the built-in mic |
| System audio + screenshots | **ScreenCaptureKit** |
| On-screen text | Apple **Vision** framework OCR |
| Echo / bleed control | Vendored **Speex** acoustic echo canceller (`ThirdParty/speexdsp`) + a text-overlap bleed filter |
| UI | SwiftUI in a non-activating `NSPanel` overlay, excluded from screen shares |

Speaker split is by source, not diarization: your built-in mic is **You**, system
audio is **Them**.

## Requirements

- **macOS 26+**, Apple Silicon
- [Ollama](https://ollama.com): run `ollama serve`, then pull a model, e.g.
  `ollama pull qwen2.5:7b` (any Ollama model works; a vision-capable model is
  needed only for the "Use screen" image mode — OCR mode works with any model)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run (dev)

```sh
xcodegen generate        # regenerate the .xcodeproj after adding/removing files
open Overhear.xcodeproj   # then ⌘R
```

The Xcode project is generated — edit `project.yml`, never the `.xcodeproj`
(it's git-ignored).

## Signing

The app uses a free Apple Development identity (own-machine use). In Xcode:
target **Overhear** → **Signing & Capabilities** → **Automatically manage
signing** → set **Team** to your Apple ID.

Entitlements (`Resources/Overhear.entitlements`):
- `com.apple.security.device.audio-input` — microphone access
- `com.apple.security.cs.disable-library-validation` — allows the vendored
  Speex C library to load under the hardened runtime

If the bundle id `com.davidwang7723.Overhear` is taken, change
`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and re-run `xcodegen generate`.

## Package a signed DMG

```sh
./build.sh        # prompts for a version, e.g. 1.0.1
```

`build.sh` regenerates the project, builds Release, signs with the first Apple
Development identity in your keychain, and writes `Overhear_vX.Y.Z.dmg` to your
Desktop. Override the identity with `OVERHEAR_SIGN_ID=<sha1-or-name> ./build.sh`.

An Apple Development signature only runs on your own machines. To share the app
with others, sign with a Developer ID certificate and notarize (`notarytool`).

## First run

Grant **Microphone** and **Screen & System Audio Recording** when prompted
(Screen Recording is what captures the other party's audio). For best accuracy
during live calls, use **headphones** — with speakers, the other side's audio
physically re-enters your mic, and while the echo canceller and bleed filter
reduce this, they can't fully remove it during simultaneous speech.

## Layout

```
Sources/
  App/            AppState (pipeline), OverhearApp (menu-bar agent)
  Audio/          mic + system-audio capture, Speex echo canceller, VAD
  Transcription/  SpeechAnalyzer wrapper
  LLM/            Ollama client + answer engine (prompt lives here)
  Store/          transcript + session persistence
  UI/             overlay panel, transcript/answer views, settings
ThirdParty/
  speexdsp/       vendored Speex DSP (BSD-3, see ThirdParty/speexdsp/COPYING)
```

## License

See [LICENSE](LICENSE). Bundled Speex DSP is BSD-3-Clause; its copyright notices
are retained in each source file and in `ThirdParty/speexdsp/COPYING`.
