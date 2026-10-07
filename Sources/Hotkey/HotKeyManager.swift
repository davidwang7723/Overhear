import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hotkey via Carbon. Works without Accessibility
/// permission (unlike NSEvent global monitors).
final class HotKeyManager {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4F564852 // 'OVHR'

    init() { installHandler() }
    deinit { unregister(); if let eventHandler { RemoveEventHandler(eventHandler) } }

    /// Register (replacing any previous) from a recorded shortcut.
    func register(_ shortcut: Shortcut) {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         Self.carbonModifiers(shortcut.cocoaModifiers),
                                         id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onTrigger?() }
            _ = event
            return noErr
        }, 1, &spec, userData, &eventHandler)
    }

    /// Cocoa modifier flags → Carbon modifier mask.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
