import AppKit
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
    var onClosed: (() -> Void)?
    private(set) var session: QuizSession?

    var isShowing: Bool { window != nil }

    /// Kiosk options. This combination follows Apple's rules:
    /// hideMenuBar needs hideDock, and the disable options need hideDock (or autoHideDock).
    private static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableHideApplication,
    ]

    func show(session: QuizSession) {
        guard window == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        self.session = session
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp = nil
        }

        let w = KioskWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.backgroundColor = Theme.windowBackground
        w.isOpaque = true
        w.hasShadow = false
        w.contentView = NSHostingView(rootView: QuizView(session: session))
        w.setFrame(screen.frame, display: true)
        window = w

        // Cover any other screens with a plain dark window.
        for other in NSScreen.screens where other != screen {
            let blank = NSWindow(contentRect: other.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            blank.isReleasedWhenClosed = false
            blank.level = .screenSaver
            blank.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            blank.backgroundColor = Theme.windowBackground
            blank.isOpaque = true
            blank.setFrame(other.frame, display: true)
            blank.orderFrontRegardless()
            blankWindows.append(blank)
        }

        savedOptions = NSApp.presentationOptions

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        bringToFront()

        // Activation can lag right after unlocking. Try again shortly.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.bringToFront()
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.bringToFront()
        }
    }

    private func bringToFront() {
        guard let w = window else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        applyKioskOptions()
    }

    private func applyKioskOptions() {
        guard window != nil else { return }
        if NSApp.presentationOptions != Self.kioskOptions {
            NSApp.presentationOptions = Self.kioskOptions
        }
    }

    @objc private func appDidBecomeActive(_ note: Notification) {
        applyKioskOptions()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func screensChanged(_ note: Notification) {
        guard let w = window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        w.setFrame(screen.frame, display: true)
    }

    func close() {
        guard let w = window else { return }
        NotificationCenter.default.removeObserver(self)

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
