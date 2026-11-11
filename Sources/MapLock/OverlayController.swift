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
    var onClosed: (() -> Void)?
    private(set) var session: QuizSession?

    var isShowing: Bool { window != nil }

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
        guard window == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

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
        bringToFront(activateApp: true)

        // The fullscreen Space often finishes activating after unlock. Try again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.bringToFront(activateApp: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.bringToFront(activateApp: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.bringToFront(activateApp: true)
        }
    }

    /// Wake, unlock, or a Space change while the quiz is already up.
    /// A Space change does not activate the app: activation would jump back to another Space.
    func reinforce(relayoutScreens: Bool, activateApp: Bool = true) {
        guard window != nil, !adjusting else { return }
        adjusting = true
        defer { adjusting = false }
        if relayoutScreens { relayout() }
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
        for blank in blankWindows {
            blank.orderOut(nil)
            blank.contentView = nil
        }
        blankWindows = []
        for other in NSScreen.screens where other != screen {
            let blank = makeCoverWindow(frame: other.frame)
            blankWindows.append(blank)
        }
    }

    private func relayout() {
        guard let existing = window else { return }
        let screens = NSScreen.screens
        guard let screen = NSScreen.main ?? screens.first else { return }
        let content = existing.contentView
        existing.orderOut(nil)
        let w = makeCoverWindow(frame: screen.frame)
        w.contentView = content
        window = w
        rebuildBlankWindows(except: screen)
    }

    private func bringToFront(activateApp: Bool) {
        guard let w = window else { return }
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
        guard let w = window else { return }
        stopWatching()

        // Put the Dock, menu bar and app switching back first.
        NSApp.presentationOptions = savedOptions

        w.orderOut(nil)
        for blank in blankWindows { blank.orderOut(nil) }
        blankWindows = []
        window = nil
        session = nil

        if let app = previousApp {
            _ = app.activate(options: [])
        }
        previousApp = nil
        onClosed?()
    }
}
