import AppKit
import SwiftUI

/// Shows a practice quiz in a normal window (no screen lock, Dock stays).
@MainActor
final class PracticeController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var closing = false
    var onClosed: (() -> Void)?

    var isShowing: Bool { window?.isVisible ?? false }

    func show(session: QuizSession) {
        closing = false
        let frame = Self.fittedFrame()
        if window == nil {
            let w = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Practice"
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.windowBackground
            w.minSize = NSSize(width: 640, height: 480)
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        w.contentView = NSHostingView(rootView: QuizView(session: session))
        w.setFrame(frame, display: true)
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// About 85% of the screen's visible area, centered, never bigger than the screen.
    private static func fittedFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(screen.width * 0.85, 640), screen.width - 40)
        let height = min(max(screen.height * 0.85, 480), screen.height - 40)
        let x = screen.midX - width / 2
        let y = screen.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func close() {
        guard !closing else { return }
        closing = true
        window?.orderOut(nil)
        window?.contentView = nil
        onClosed?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}
