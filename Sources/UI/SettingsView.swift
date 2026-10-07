import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            vision.tabItem { Label("Vision", systemImage: "eye") }
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }
            ollama.tabItem { Label("Ollama", systemImage: "cpu") }
        }
        .frame(width: 460, height: 360)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Overlay") {
                HStack {
                    Text("Show / hide hotkey")
                    Spacer()
                    ShortcutField(shortcut: $settings.toggleShortcut)
                        .frame(width: 140, height: 24)
                }
                Picker("Window pinning", selection: $settings.pinMode) {
                    ForEach(PinMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Opacity: \(Int(settings.opacity * 100))%")
                    Slider(value: $settings.opacity, in: 0.3...1.0)
                }
            }
            Section {
                Label("Overhear is hidden from screen shares and recordings.",
                      systemImage: "eye.slash")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Vision

    private var vision: some View {
        Form {
            Section("What the model sees") {
                Picker("Capture", selection: $settings.captureTarget) {
                    ForEach(CaptureTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Used when “Use screen” is on. A live screenshot is attached "
                     + "to the answer so a vision model can read slides, code, or "
                     + "whiteboards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Model", selection: $state.selectedModel) {
                    ForEach(state.availableModels, id: \.self) { Text($0).tag($0) }
                }
                if !state.selectedModelIsVisionCapable {
                    Label("This model likely can't read images. Pull a vision model "
                          + "like llava or qwen2.5vl.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions

    private var permissions: some View {
        Form {
            Section("Required") {
                permissionRow("Microphone", PermissionsService.microphone) {
                    PermissionsService.openMicrophoneSettings()
                }
                permissionRow("Screen Recording", PermissionsService.screenRecording) {
                    PermissionsService.requestScreenRecording()
                    PermissionsService.openScreenRecordingSettings()
                }
            }
            Section {
                Text("Screen Recording covers both system-audio capture (their "
                     + "voice) and screenshots for vision. Everything stays on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone isolation") {
                HStack {
                    Text("Mic mode")
                    Spacer()
                    Text(MicModeService.activeLabel)
                        .foregroundStyle(MicModeService.isVoiceIsolationActive ? .green : .secondary)
                    Button("Change…") { MicModeService.showPicker() }
                }
                Text("Set this to Voice Isolation to strip background noise and "
                     + "speaker bleed using the Neural Engine, keeping just your "
                     + "voice on the mic channel.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Echo handling is automatic: speaker bleed is cancelled or "
                     + "filtered out of the transcript, and it steps aside while "
                     + "a meeting app is running so the meeting hears you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ name: String, _ st: PermissionsService.State,
                               action: @escaping () -> Void) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch st {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            default:
                Button("Grant…", action: action)
            }
        }
    }

    // MARK: - Ollama

    private var ollama: some View {
        Form {
            Section("Local LLM server") {
                HStack {
                    Text("Status")
                    Spacer()
                    if state.ollamaReachable {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Label("Not reachable", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).labelStyle(.titleAndIcon)
                    }
                }
                Button("Recheck") { Task { await state.refreshModels() } }
            }
            Section("Setup") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Install Ollama from ollama.com").font(.caption)
                    Text("2. Start it:  ollama serve").font(.caption).monospaced()
                    Text("3. Pull a model:").font(.caption)
                    Text("   ollama pull qwen2.5:7b").font(.caption).monospaced()
                    Text("   ollama pull llava   # vision").font(.caption).monospaced()
                }
                if state.availableModels.isEmpty {
                    Label("No models found.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("\(state.availableModels.count) model(s) installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
