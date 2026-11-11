import AppKit
import CoreGraphics
import SwiftUI

/// A non-activating panel can sit on another app's fullscreen Space. A normal window cannot.
final class KioskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the quiz as a full screen "kiosk" overlay and puts things back when done.
@MainActor
final class OverlayController: NSObject {
    private var window: KioskPanel?
    private var blankWindows: [NSWindow] = []
    private var savedOptions: NSApplication.PresentationOptions = []
    private var previousApp: NSRunningApplication?
    /// Stops a screen-change notice from rebuilding the windows while a rebuild is already running.
    private var adjusting = false
    /// True only while a quiz session should be covering the screen. Cleared before teardown.
    private var lockActive = false
    private var closing = false
    private var followUp: Task<Void, Never>?
    private var reinforceTask: Task<Void, Never>?
    private var wantRelayout = false
    private var wantActivate = false
    private var escapeMonitor: Any?
    private var escapeMonitorInstalled = false
    /// Shields taken off screen. Held so a window animation can finish before dealloc.
    private var retired: [NSWindow] = []
    /// Every shield we created, so dismiss can release one that a rebuild swapped in.
    private var covers: [KioskPanel] = []
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

    func show(session: QuizSession) {
        if !lockActive { destroyShields() }
        guard !lockActive, window == nil, covers.isEmpty else { return }

        lockActive = true
        self.session = session
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp = nil
        }
        // Watch before the Dock restart, so a Space change from it still rebuilds the shield.
        startWatching()
        TrackpadSwipeGuard.suspend()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            lockActive = false
            self.session = nil
            reinforceTask?.cancel()
            stopWatching()
            TrackpadSwipeGuard.restore()
            return
        }
        becomeAccessory()
        guard let w = makeCoverWindow(frame: screen.frame) else {
            lockActive = false
            self.session = nil
            reinforceTask?.cancel()
            stopWatching()
            TrackpadSwipeGuard.restore()
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            return
        }
        w.contentView = NSHostingView(rootView: QuizView(session: session))
        window = w
        rebuildBlankWindows(except: screen)

        savedOptions = NSApp.presentationOptions
        startEscapeMonitor()
        bringToFront(activateApp: true)
        TrackpadSwipeGuard.noteLockedSpace()
        scheduleLateRejoin()
    }

    /// The fullscreen Space often becomes active after the quiz window already exists.
    /// A window kept from the desktop Space does not follow it, so these rebuild the shield.
    private func scheduleLateRejoin() {
        followUp?.cancel()
        followUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, self.lockActive else { return }
            self.rejoinCurrentSpace()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, self.lockActive else { return }
            self.rejoinCurrentSpace()
        }
    }

    /// New shield windows on the Space that is active right now, then order them front.
    private func rejoinCurrentSpace() {
        guard !closing, lockActive, !adjusting else { return }
        becomeAccessory()
        guard session != nil, window?.contentView != nil else {
            // The shield is still being built, often after the Dock restart. Don't end the lock.
            if lockActive { return }
            close()
            return
        }
        adjusting = true
        defer { adjusting = false }
        recreateShields()
        guard lockActive else { return }
        bringToFront(activateApp: true)
    }

    /// Wake, unlock, or a Space change while the quiz is already up.
    /// Several of those notices arrive together; doing the work once avoids
    /// tearing a window down while AppKit is still animating it on screen.
    func reinforce(relayoutScreens: Bool, activateApp: Bool = true) {
        guard !closing else { return }
        guard lockActive else {
            parkStrays()
            return
        }
        wantRelayout = wantRelayout || relayoutScreens
        wantActivate = wantActivate || activateApp
        reinforceTask?.cancel()
        reinforceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled, !self.closing else { return }
            let relayoutNow = self.wantRelayout
            let activateNow = self.wantActivate
            self.wantRelayout = false
            self.wantActivate = false
            self.performReinforce(relayoutScreens: relayoutNow, activateApp: activateNow)
        }
    }

    private func performReinforce(relayoutScreens: Bool, activateApp: Bool) {
        guard !closing else { return }
        if adjusting { return }
        if lockActive { becomeAccessory() }
        guard lockActive else {
            parkStrays()
            return
        }
        guard session != nil, window?.contentView != nil else {
            if lockActive { return }
            close()
            return
        }
        adjusting = true
        defer { adjusting = false }
        if relayoutScreens { recreateShields() }
        guard lockActive else { return }
        bringToFront(activateApp: activateApp)
    }

    private func makeCoverWindow(frame: NSRect) -> KioskPanel? {
        guard lockActive, !closing else { return nil }
        let w = KioskPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
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
            park(blank)
        }
        guard lockActive else { return }
        for other in NSScreen.screens where other != screen {
            guard let blank = makeCoverWindow(frame: other.frame) else { continue }
            blankWindows.append(blank)
        }
    }

    /// A reused window stays glued to the desktop Space it was born on, so a fullscreen
    /// app's Space never sees it. Build a new one while that Space is active, and keep
    /// the old one alive until AppKit is done with it.
    private func recreateShields() {
        guard lockActive, let existing = window, let content = existing.contentView, session != nil else {
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard let w = makeCoverWindow(frame: screen.frame) else { return }
        w.contentView = content
        window = w
        let oldBlanks = blankWindows
        blankWindows = []
        park(existing)
        for blank in oldBlanks {
            park(blank)
        }
        guard lockActive else { return }
        for other in NSScreen.screens where other != screen {
            guard let blank = makeCoverWindow(frame: other.frame) else { continue }
            blankWindows.append(blank)
        }
    }

    /// Hide a shield and keep it alive until its AppKit animation has finished.
    private func park(_ w: NSWindow) {
        covers.removeAll { $0 === w }
        blankWindows.removeAll { $0 === w }
        if window === w { window = nil }
        w.orderOut(nil)
        if retired.contains(where: { $0 === w }) { return }
        retired.append(w)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.retired.removeAll { $0 === w }
        }
    }

    private func bringToFront(activateApp: Bool) {
        guard lockActive, let w = window, w.contentView != nil, session != nil else {
            if window != nil || !covers.isEmpty { close() }
            return
        }
        becomeAccessory()
        applyLockBehavior(to: w)
        for blank in blankWindows {
            applyLockBehavior(to: blank)
            blank.orderFrontRegardless()
        }
        // The panel has to be on this Space before the app activates, or macOS
        // switches to the desktop Space where a regular app's window lives.
        w.orderFrontRegardless()
        w.makeKey()
        guard activateApp else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.orderFrontRegardless()
    }

    /// Accessory apps are the ones macOS will draw over another app's fullscreen Space.
    private func becomeAccessory() {
        guard lockActive, !closing else { return }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func appDidBecomeActive(_ note: Notification) {
        bringToFront(activateApp: false)
    }

    @objc private func screensChanged(_ note: Notification) {
        reinforce(relayoutScreens: true)
    }

    /// A Space swipe, including into a fullscreen app. Rebuild so the shield is born on that Space.
    /// A swipe the event tap missed is sent back to the Space the lock was shown on first.
    @objc private func spaceChanged(_ note: Notification) {
        if TrackpadSwipeGuard.holdSpaceIfNeeded() { return }
        reinforce(relayoutScreens: true, activateApp: true)
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
        reinforce(relayoutScreens: true, activateApp: true)
        scheduleLateRejoin()
    }

    @objc private func sessionBack(_ note: Notification) {
        reinforce(relayoutScreens: true, activateApp: true)
        scheduleLateRejoin()
    }

    @objc private func screenUnlocked(_ note: Notification) {
        reinforce(relayoutScreens: true, activateApp: true)
        scheduleLateRejoin()
    }

    private func stopWatching() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func close() {
        guard !closing else { return }
        let shieldsLeft = !visibleShields().isEmpty
        guard lockActive || window != nil || !covers.isEmpty || shieldsLeft else {
            // A crash during a quiz leaves the backup even when no shield is up.
            TrackpadSwipeGuard.restore()
            return
        }
        closing = true
        // Clear this before any window or Space change, so a notification from
        // teardown cannot build a new empty shield.
        lockActive = false
        followUp?.cancel()
        followUp = nil
        reinforceTask?.cancel()
        reinforceTask = nil
        wantRelayout = false
        wantActivate = false
        stopWatching()

        if NSApp.presentationOptions != savedOptions {
            NSApp.presentationOptions = savedOptions
        }

        destroyShields()
        TrackpadSwipeGuard.restore()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // AppKit can order the same window back on at the end of this event.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.lockActive, !self.closing else { return }
            self.destroyShields()
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }

        let app = previousApp
        previousApp = nil
        closing = false
        if let app {
            _ = app.activate(options: [])
        }
        onClosed?()
    }

    /// Order out every shield we created. Only KioskPanel instances, never another AppKit window.
    private func destroyShields() {
        let doomed = covers + visibleShields()
        window = nil
        session = nil
        var seen = Set<ObjectIdentifier>()
        for w in doomed {
            let id = ObjectIdentifier(w)
            if seen.contains(id) { continue }
            seen.insert(id)
            park(w)
        }
    }

    /// Shields still on screen. Other borderless windows (toasts, menus) are left alone.
    private func visibleShields() -> [NSWindow] {
        NSApp.windows.filter { $0 is KioskPanel && $0.isVisible }
    }

    private func parkStrays() {
        guard !lockActive, !closing else { return }
        for candidate in visibleShields() {
            park(candidate)
        }
    }

    /// True when a shield is up but it is not a live quiz. Clicks and Escape may dismiss it.
    private var stuckShield: Bool {
        if adjusting || closing || lockActive { return false }
        return !visibleShields().isEmpty || window != nil || !covers.isEmpty
    }

    private func startEscapeMonitor() {
        guard !escapeMonitorInstalled else { return }
        escapeMonitorInstalled = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown]
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .keyDown, event.keyCode != 53 { return event }
            let stuck = MainActor.assumeIsolated { self?.stuckShield ?? false }
            guard stuck else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }
}

