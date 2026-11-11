import AppKit
import CoreGraphics
import SwiftUI

/// Borderless windows cannot take keyboard input unless they say they can.
final class KioskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the quiz as a full screen "kiosk" overlay and puts things back when done.
@MainActor
final class OverlayController: NSObject {
    private var window: KioskWindow?
    private var blankWindows: [NSWindow] = []
    private var savedOptions: NSApplication.PresentationOptions = []
    private var previousApp: NSRunningApplication?
    /// Stops a screen-change notice from rebuilding the windows while a rebuild is already running.
    private var adjusting = false
    /// True while the quiz window is being swapped, so a nested order-front cannot revive the old one.
    private var replacing = false
    /// True only while a quiz session should be covering the screen. Cleared before teardown.
    private var lockActive = false
    private var closing = false
    private var followUp: Task<Void, Never>?
    private var escapeMonitor: Any?
    /// Every shield we created, so dismiss can release one that a rebuild swapped in.
    private var covers: [KioskWindow] = []
    var onClosed: (() -> Void)?
    private(set) var session: QuizSession?

    var isShowing: Bool { lockActive && window != nil }

    /// Above fullscreen apps. The screen-saver level is not enough on a fullscreen Space.
    private static let lockLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    /// Join every Space, including one that a fullscreen app owns, and stay put in Mission Control.
    private static let lockBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    /// Kiosk options. This combination follows Apple's rules:
    /// hideMenuBar needs hideDock, disableAppleMenu needs hideMenuBar,
    /// and the disable options need hideDock (or autoHideDock).
    private static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication,
        .disableMenuBarTransparency,
    ]

    func show(session: QuizSession) {
        guard !lockActive, window == nil, covers.isEmpty else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        lockActive = true
        self.session = session
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp = nil
        }

        let w = makeCoverWindow(frame: screen.frame)
        w.contentView = NSHostingView(rootView: QuizView(session: session))
        window = w
        rebuildBlankWindows(except: screen)

        savedOptions = NSApp.presentationOptions
        startWatching()
        startEscapeMonitor()
        bringToFront(activateApp: true)

        // The fullscreen Space often finishes activating after unlock. Try again.
        followUp?.cancel()
        followUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, self.lockActive else { return }
            self.bringToFront(activateApp: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, self.lockActive else { return }
            self.bringToFront(activateApp: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self.lockActive else { return }
            self.bringToFront(activateApp: true)
        }
    }

    /// Wake, unlock, or a Space change while the quiz is already up.
    /// A Space change does not activate the app: activation would jump back to another Space.
    func reinforce(relayoutScreens: Bool, activateApp: Bool = true) {
        guard !closing else { return }
        if adjusting || replacing { return }
        guard lockActive else {
            if window != nil || !covers.isEmpty { close() }
            return
        }
        guard session != nil, window?.contentView != nil else {
            close()
            return
        }
        adjusting = true
        defer { adjusting = false }
        if relayoutScreens { relayout() }
        guard lockActive else { return }
        bringToFront(activateApp: activateApp)
    }

    private func makeCoverWindow(frame: NSRect) -> KioskWindow {
        let w = KioskWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.windowBackground
        w.isOpaque = true
        w.hasShadow = false
        w.isMovable = false
        w.hidesOnDeactivate = false
        w.canHide = false
        w.ignoresMouseEvents = false
        applyLockBehavior(to: w)
        w.setFrame(frame, display: true)
        covers.append(w)
        return w
    }

    /// Clear the behavior first. After sleep the window server drops the old Space attachment,
    /// and setting the same flags again is not enough to join a fullscreen Space.
    private func applyLockBehavior(to w: NSWindow) {
        w.level = Self.lockLevel
        w.collectionBehavior = []
        w.collectionBehavior = Self.lockBehavior
    }

    private func rebuildBlankWindows(except screen: NSScreen) {
        let old = blankWindows
        blankWindows = []
        for blank in old {
            covers.removeAll { $0 === blank }
            retire(blank)
        }
        guard lockActive else { return }
        for other in NSScreen.screens where other != screen {
            let blank = makeCoverWindow(frame: other.frame)
            blankWindows.append(blank)
        }
    }

    private func relayout() {
        guard lockActive, let existing = window, let content = existing.contentView, session != nil else {
            close()
            return
        }
        let screens = NSScreen.screens
        guard let screen = NSScreen.main ?? screens.first else { return }
        covers.removeAll { $0 === existing }
        replacing = true
        retire(existing)
        replacing = false
        guard lockActive else { return }
        let w = makeCoverWindow(frame: screen.frame)
        w.contentView = content
        window = w
        rebuildBlankWindows(except: screen)
    }

    /// Drop a shield below every other window, then hide it. A shielding-level window can ignore orderOut.
    private func retire(_ w: NSWindow) {
        w.level = .normal
        w.collectionBehavior = []
        w.orderOut(nil)
        w.contentView = nil
        w.close()
    }

    private func bringToFront(activateApp: Bool) {
        guard !replacing else { return }
        guard lockActive, let w = window, w.contentView != nil, session != nil else {
            if window != nil || !covers.isEmpty { close() }
            return
        }
        applyLockBehavior(to: w)
        for blank in blankWindows {
            applyLockBehavior(to: blank)
            blank.orderFrontRegardless()
        }
        // Order onto the current Space before activating, so activation does not
        // pull the user off a fullscreen Space and leave that Space uncovered.
        w.orderFrontRegardless()
        applyKioskOptions()
        if activateApp {
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate(ignoringOtherApps: true)
        }
        w.makeKey()
        w.orderFrontRegardless()
    }

    private func applyKioskOptions() {
        guard window != nil else { return }
        if NSApp.presentationOptions != Self.kioskOptions {
            NSApp.presentationOptions = Self.kioskOptions
        }
    }

    @objc private func appDidBecomeActive(_ note: Notification) {
        bringToFront(activateApp: false)
    }

    @objc private func screensChanged(_ note: Notification) {
        reinforce(relayoutScreens: true)
    }

    /// A Space swipe. Re-show the cover on the Space that just became active, without
    /// activating the app (that would jump back to the Space the window was created on).
    @objc private func spaceChanged(_ note: Notification) {
        reinforce(relayoutScreens: false, activateApp: false)
    }

    private func startWatching() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(screensChanged(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(spaceChanged(_:)),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke(_:)),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBack(_:)),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func screensWoke(_ note: Notification) {
        reinforce(relayoutScreens: true)
    }

    @objc private func sessionBack(_ note: Notification) {
        reinforce(relayoutScreens: false)
    }

    @objc private func screenUnlocked(_ note: Notification) {
        reinforce(relayoutScreens: false)
    }

    private func stopWatching() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func close() {
        guard !closing else { return }
        guard lockActive || window != nil || !covers.isEmpty else { return }
        closing = true
        // Clear this before any window or Space change, so a notification from
        // teardown cannot build a new empty shield.
        lockActive = false
        followUp?.cancel()
        followUp = nil
        stopEscapeMonitor()
        stopWatching()

        let restore = savedOptions == Self.kioskOptions ? [] : savedOptions
        NSApp.presentationOptions = restore

        let doomed = covers
        covers = []
        blankWindows = []
        window = nil
        session = nil
        for w in doomed {
            retire(w)
        }

        let app = previousApp
        previousApp = nil
        closing = false
        if let app {
            _ = app.activate(options: [])
        }
        onClosed?()
    }

    /// True when a shield is up but it is not a live quiz. Clicks and Escape may dismiss it.
    private var stuckShield: Bool {
        if adjusting || closing { return false }
        let shieldsUp = window != nil || !covers.isEmpty
        guard shieldsUp else { return false }
        if !lockActive { return true }
        return window?.contentView == nil
    }

    private func startEscapeMonitor() {
        stopEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode != 53 { return event }
            let stuck = MainActor.assumeIsolated { self?.stuckShield ?? false }
            guard stuck else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
