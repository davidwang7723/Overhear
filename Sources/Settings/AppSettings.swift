import Foundation
import AppKit
import Combine

/// A recorded global keyboard shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Cocoa modifier flags raw value (device-independent subset).
    var modifiers: UInt
    var display: String

    var cocoaModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Default: ⌥⌘O (keyCode 31 = "o").
    static let defaultToggle = Shortcut(
        keyCode: 31,
        modifiers: (NSEvent.ModifierFlags.option.union(.command)).rawValue,
        display: "⌥⌘O")
}

/// How the overlay layers against other windows.
enum PinMode: String, Codable, CaseIterable {
    case pinned    // always on top (floating), joins all Spaces
    case normal    // ordinary window — other apps can cover it

    var label: String { self == .pinned ? "Pinned (always on top)" : "Normal (coverable)" }
}

/// Which surface the vision model looks at.
enum CaptureTarget: String, Codable, CaseIterable {
    case fullDisplay
    case frontmostWindow

    var label: String {
        self == .fullDisplay ? "Whole screen" : "Frontmost window"
    }
}

/// User-facing preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var toggleShortcut: Shortcut { didSet { save(\.toggleShortcut, "toggleShortcut") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var pinMode: PinMode { didSet { saveRaw(pinMode.rawValue, "pinMode") } }
    @Published var captureTarget: CaptureTarget { didSet { saveRaw(captureTarget.rawValue, "captureTarget") } }
    /// One-time: whether we've already nudged the user toward Voice Isolation.
    @Published var didPromptVoiceIsolation: Bool {
        didSet { defaults.set(didPromptVoiceIsolation, forKey: "didPromptVoiceIsolation") }
    }
    /// When true the overlay is excluded from all screen capture / sharing
    /// (invisible in Zoom/QuickTime/screenshots). Off = a normal window that
    /// shows up in recordings. Default on.
    @Published var invisible: Bool {
        didSet { defaults.set(invisible, forKey: "invisible") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        toggleShortcut = Self.decode(Shortcut.self, "toggleShortcut", from: d) ?? .defaultToggle
        opacity = d.object(forKey: "opacity") as? Double ?? 1.0
        pinMode = PinMode(rawValue: d.string(forKey: "pinMode") ?? "") ?? .pinned
        captureTarget = CaptureTarget(rawValue: d.string(forKey: "captureTarget") ?? "") ?? .fullDisplay
        didPromptVoiceIsolation = d.bool(forKey: "didPromptVoiceIsolation")
        invisible = d.object(forKey: "invisible") as? Bool ?? true
    }

    private func save<T: Encodable>(_ keyPath: KeyPath<AppSettings, T>, _ key: String) {
        if let data = try? JSONEncoder().encode(self[keyPath: keyPath]) {
            defaults.set(data, forKey: key)
        }
    }
    private func saveRaw(_ value: String, _ key: String) { defaults.set(value, forKey: key) }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String,
                                             from d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
