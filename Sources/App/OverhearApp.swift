import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Posted when the menu-bar "Settings…" item is chosen; the overlay switches
    /// to its inline settings pane.
    static let overhearShowSettings = Notification.Name("overhearShowSettings")
}

@main
struct OverhearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu-bar item is a custom NSStatusItem (see AppDelegate) so we can
        // give left- and right-click different behaviors. Settings is the app's
        // only SwiftUI scene.
        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    private let panel = PanelController()
    private let hotKeys = HotKeyManager()
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        panel.show(state: AppState.shared)

        // Global toggle hotkey, re-registered whenever the user rebinds it.
        hotKeys.onTrigger = { [weak self] in self?.toggleOverlay() }
        hotKeys.register(AppSettings.shared.toggleShortcut)
        AppSettings.shared.$toggleShortcut
            .sink { [weak self] in self?.hotKeys.register($0) }
            .store(in: &cancellables)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "Overhear")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Left-click: show/hide  •  Right-click: menu"
        }
        statusItem = item
    }

    /// Left-click (or plain click) toggles the overlay; right-click (or
    /// control-click) shows the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            toggleOverlay()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let listen = NSMenuItem(
            title: AppState.shared.isListening ? "Stop Listening" : "Start Listening",
            action: #selector(toggleListening), keyEquivalent: "")
        listen.target = self
        menu.addItem(listen)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Overhear",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func toggleListening() { AppState.shared.toggleListening() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    /// Show the overlay (if hidden) and switch it to its inline settings pane.
    /// The old separate Settings window was buggy behind the floating panel.
    @objc func openSettings() {
        panel.show(state: AppState.shared)
        NotificationCenter.default.post(name: .overhearShowSettings, object: nil)
    }

    func toggleOverlay() {
        panel.toggle(state: AppState.shared)
    }

    /// Resize the overlay for the AI-only compact mode (and back).
    func setOverlayCompact(_ compact: Bool) {
        panel.setCompact(compact)
    }
}
