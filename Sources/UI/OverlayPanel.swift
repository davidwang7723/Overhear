import AppKit
import SwiftUI
import Combine

/// A borderless, non-activating panel that hosts the overlay UI. It never becomes
/// main (so it won't steal focus from Zoom/the browser) and is excluded from
/// screen capture so it stays invisible in meeting screen-shares.
final class OverlayPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                   styleMask: [.nonactivatingPanel, .borderless, .resizable],
                   backing: .buffered,
                   defer: false)

        // Below this the layout breaks (rounded corners clip square, controls
        // get cut off). AppKit enforces it during user resizes.
        minSize = NSSize(width: 880, height: 540)

        isFloatingPanel = true
        // NSPanel defaults to hiding whenever the app deactivates — which is
        // every desktop swipe / click into another app. Never auto-hide.
        hidesOnDeactivate = false
        // Take keyboard focus ONLY when the user clicks a text field in the
        // panel — otherwise the floating panel silently keeps key status and
        // typing in other apps' fields goes nowhere.
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        // Exclude from ALL screen capture / sharing (ScreenCaptureKit, Zoom,
        // Meet, QuickTime) so Overhear is invisible to a share. Live-toggled
        // via AppSettings.invisible.
        applyInvisible(AppSettings.shared.invisible)

        // Always render dark so the white text/symbols stay legible regardless
        // of the system light/dark setting.
        appearance = NSAppearance(named: .darkAqua)

        applyPin(.pinned)

        let hosting = NSHostingView(rootView: rootView)
        // Avoid the intermittent EXC_BREAKPOINT from Auto Layout on a
        // fixed-frame hosting view in a panel.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = contentView?.bounds ?? .zero
        contentView?.addSubview(hosting)

        // Fat resize grips on the edges/corners — the borderless panel's
        // built-in resize zone is only a few pixels and hard to hit.
        let grips = ResizeGripView(frame: contentView?.bounds ?? .zero)
        grips.autoresizingMask = [.width, .height]
        contentView?.addSubview(grips, positioned: .above, relativeTo: hosting)
    }

    // Allow keyboard input to reach fields without activating the app.
    override var canBecomeKey: Bool { true }

    /// Mission Control click: the panel briefly becomes key while the app is
    /// still inactive, then AppKit reorders it behind the active app's
    /// windows. Activating right here keeps the panel front. Direct clicks on
    /// the panel never become key (nonactivating + becomesKeyOnlyIfNeeded), so
    /// meeting-app focus is untouched in normal use.
    override func becomeKey() {
        super.becomeKey()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            orderFrontRegardless()
        }
    }
    // Main is allowed so a Mission Control click can land on the panel and
    // keep it fronted (AppKit demotes windows that refuse main). Normal clicks
    // still never activate the app — the .nonactivatingPanel style handles
    // focus protection, not this flag.
    override var canBecomeMain: Bool { true }

    /// ⌘W hides the overlay (same as the Close button). The borderless panel
    /// has no titlebar close button, so handle the key equivalent directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Pinned = always on top across Spaces. Normal = an ordinary window other
    /// apps can cover.
    func applyPin(_ mode: PinMode) {
        switch mode {
        case .pinned:
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        case .normal:
            level = .normal
            // Still follows the user across Spaces — "normal" only means other
            // windows can cover it.
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    /// Invisible = excluded from every screen capture / share. Visible = a
    /// normal window that appears in recordings.
    func applyInvisible(_ invisible: Bool) {
        sharingType = invisible ? .none : .readOnly
    }

    func positionTopTrailing() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        let origin = NSPoint(x: visible.maxX - frame.width - margin,
                             y: visible.maxY - frame.height - margin)
        setFrameOrigin(origin)
    }
}

/// Transparent overlay that turns a 10pt band along the window's edges and
/// corners into resize grips (with the proper resize cursors). Clicks in the
/// interior pass straight through to the UI / window-move behavior.
private final class ResizeGripView: NSView {
    private let grip: CGFloat = 10

    private struct Edge: OptionSet {
        let rawValue: Int
        static let left   = Edge(rawValue: 1 << 0)
        static let right  = Edge(rawValue: 1 << 1)
        static let bottom = Edge(rawValue: 1 << 2)
        static let top    = Edge(rawValue: 1 << 3)
    }

    private var active: Edge = []
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edge(at p: NSPoint) -> Edge {
        var e: Edge = []
        if p.x < grip { e.insert(.left) }
        if p.x > bounds.maxX - grip { e.insert(.right) }
        if p.y < grip { e.insert(.bottom) }
        if p.y > bounds.maxY - grip { e.insert(.top) }
        return e
    }

    // Only claim clicks in the edge band; everything else falls through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return edge(at: p).isEmpty ? nil : self
    }

    override func resetCursorRects() {
        let b = bounds
        let horiz = NSCursor.resizeLeftRight
        let vert = NSCursor.resizeUpDown
        addCursorRect(NSRect(x: 0, y: grip, width: grip, height: b.height - 2 * grip),
                      cursor: horiz)
        addCursorRect(NSRect(x: b.maxX - grip, y: grip, width: grip, height: b.height - 2 * grip),
                      cursor: horiz)
        addCursorRect(NSRect(x: grip, y: 0, width: b.width - 2 * grip, height: grip),
                      cursor: vert)
        addCursorRect(NSRect(x: grip, y: b.maxY - grip, width: b.width - 2 * grip, height: grip),
                      cursor: vert)
        // Corners: diagonal frame-resize cursors.
        addCursorRect(NSRect(x: 0, y: 0, width: grip, height: grip),
                      cursor: .frameResize(position: .bottomLeft, directions: .all))
        addCursorRect(NSRect(x: b.maxX - grip, y: 0, width: grip, height: grip),
                      cursor: .frameResize(position: .bottomRight, directions: .all))
        addCursorRect(NSRect(x: 0, y: b.maxY - grip, width: grip, height: grip),
                      cursor: .frameResize(position: .topLeft, directions: .all))
        addCursorRect(NSRect(x: b.maxX - grip, y: b.maxY - grip, width: grip, height: grip),
                      cursor: .frameResize(position: .topRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        active = edge(at: convert(event.locationInWindow, from: nil))
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !active.isEmpty else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        var f = startFrame
        let minW = window.minSize.width
        let minH = window.minSize.height

        if active.contains(.right) {
            f.size.width = max(minW, startFrame.width + dx)
        }
        if active.contains(.left) {
            let w = max(minW, startFrame.width - dx)
            f.origin.x = startFrame.maxX - w
            f.size.width = w
        }
        if active.contains(.top) {
            f.size.height = max(minH, startFrame.height + dy)
        }
        if active.contains(.bottom) {
            let h = max(minH, startFrame.height - dy)
            f.origin.y = startFrame.maxY - h
            f.size.height = h
        }
        window.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        active = []
    }
}

/// Creates and manages the overlay panel's lifecycle and live-applies settings.
@MainActor
final class PanelController {
    private var panel: OverlayPanel?
    private var cancellables: Set<AnyCancellable> = []

    func show(state: AppState) {
        if panel == nil {
            let root = OverlayView()
                .environmentObject(state)
                .environmentObject(AppSettings.shared)
            let p = OverlayPanel(rootView: root)
            p.positionTopTrailing()
            panel = p
            observeSettings()
            applySettings()
            // Mission Control: clicking the panel brings it forward, but the
            // nonactivating panel can't become main, so AppKit immediately
            // re-orders it behind the previous app. Re-front on activation and
            // Space changes.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refrontIfVisible() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refrontIfVisible() }
            }
        }
        panel?.orderFrontRegardless()
    }

    private func refrontIfVisible() {
        if let panel, panel.isVisible { panel.orderFrontRegardless() }
    }

    func toggle(state: AppState) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(state: state)
        }
    }

    /// Swap between the full two-column window and the small AI-only window,
    /// keeping the top-right corner anchored so it doesn't jump around.
    func setCompact(_ compact: Bool) {
        guard let panel else { return }
        let size = compact ? NSSize(width: 380, height: 460)
                           : NSSize(width: 920, height: 560)
        panel.minSize = compact ? NSSize(width: 340, height: 420)
                                : NSSize(width: 880, height: 540)
        var frame = panel.frame
        frame.origin = NSPoint(x: frame.maxX - size.width,
                               y: frame.maxY - size.height)
        frame.size = size
        // No animation: SwiftUI lays the content out mid-animation and AppKit
        // switches (the toggle pills) come back rendered as solid blobs.
        panel.setFrame(frame, display: true, animate: false)
    }

    private func observeSettings() {
        let settings = AppSettings.shared
        settings.$opacity.sink { [weak self] value in
            self?.panel?.alphaValue = CGFloat(value)
        }.store(in: &cancellables)
        settings.$pinMode.sink { [weak self] mode in
            self?.panel?.applyPin(mode)
            self?.panel?.orderFrontRegardless()
        }.store(in: &cancellables)
        settings.$invisible.sink { [weak self] on in
            self?.panel?.applyInvisible(on)
        }.store(in: &cancellables)
    }

    private func applySettings() {
        let settings = AppSettings.shared
        panel?.alphaValue = CGFloat(settings.opacity)
        panel?.applyPin(settings.pinMode)
    }
}
