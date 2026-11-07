import AppKit
import SwiftUI

@MainActor
final class RaceController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var closing = false
    var onClosed: (() -> Void)?
    var isShowing: Bool { window?.isVisible ?? false }

    func show(session: RaceSession) {
        closing = false
        let frame = PracticeFrame.fitted()
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.windowBackground
            w.minSize = NSSize(width: 640, height: 480)
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        w.title = "Race"
        session.onClose = { [weak self] in self?.close() }
        w.contentView = NSHostingView(rootView: RaceView(session: session))
        w.setFrame(frame, display: true)
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        session.connect()
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

/// Opens the system share menu for a race link.
struct RaceShareButton: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        context.coordinator.text = text
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.text = text
        button.title = "Share"
    }

    final class Coordinator: NSObject {
        var text = ""
        private var picker: NSSharingServicePicker?

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: [text])
            self.picker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

enum PracticeFrame {
    static func fitted() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(screen.width * 0.85, 640), screen.width - 40)
        let height = min(max(screen.height * 0.85, 480), screen.height - 40)
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }
}

struct RaceView: View {
    @ObservedObject var session: RaceSession

    var body: some View {
        ZStack {
            QuizView(session: session.quiz)
            if session.phase == "waiting" || session.phase == "countdown" {
                Theme.background.opacity(0.94).ignoresSafeArea()
                VStack(spacing: Theme.Space.s4) {
                    if session.phase == "countdown" {
                        Text(session.countdown.map(String.init) ?? "1")
                            .font(.system(size: 96, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Get ready")
                            .font(Theme.font(Theme.Size.md, .semibold))
                    } else {
                        Text("Waiting for your friend")
                            .font(Theme.font(Theme.Size.lg, .semibold))
                        Text(session.ticket.code)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Text(session.ticket.webUrl)
                            .font(Theme.font(Theme.Size.sm))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        HStack(spacing: Theme.Space.s2) {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.ticket.webUrl, forType: .string)
                            }
                            .buttonStyle(AppButtonStyle(kind: .primary, height: 36))
                            RaceShareButton(text: session.ticket.webUrl)
                                .frame(width: 96, height: 36)
                        }
                    }
                    Text(SpeedrunKey.title(SpeedrunKey.make(
                        subject: QuizSubject(rawValue: session.ticket.subject) ?? .countries,
                        style: PracticeAnswerStyle(rawValue: session.ticket.style) ?? .clickMap,
                        scope: StatsScopeKey.from(practiceScope: session.scope)
                    )))
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                }
                .padding(Theme.Space.s6)
                .frame(maxWidth: 520)
            }
            if session.phase == "racing" {
                VStack {
                    opponentBar
                        .padding(Theme.Space.s4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                        .padding(.top, Theme.Space.s3)
                        .padding(.horizontal, Theme.Space.s4)
                    Spacer()
                }
                .allowsHitTesting(false)
                VStack {
                    Spacer()
                    Button("Forfeit") { session.forfeit() }
                        .buttonStyle(AppButtonStyle(kind: .danger))
                        .padding(.bottom, Theme.Space.s4)
                }
            }
            if session.phase == "finished" {
                Theme.scrim.ignoresSafeArea()
                RaceResultView(session: session)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private var opponentBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.opponentName)
                    .font(Theme.font(Theme.Size.sm, .semibold))
                Spacer()
                Text(opponentLine)
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
            }
            ProgressView(value: Double(session.opponentFound), total: Double(max(session.opponentTotal, 1)))
                .tint(Theme.accent)
        }
    }

    private var opponentLine: String {
        let penalty = session.opponentMisses * 3 + session.opponentSkips * 10
        var text = "\(session.opponentFound) of \(session.opponentTotal), \(session.opponentMisses) misses, \(session.opponentSkips) skips"
        if penalty > 0 { text += " (+\(penalty)s)" }
        return text
    }
}

private struct RaceResultView: View {
    @ObservedObject var session: RaceSession

    var body: some View {
        VStack(spacing: Theme.Space.s3) {
            Text(title)
                .font(Theme.font(Theme.Size.xl, .bold))
            timeRow("You", elapsed: session.youElapsed, forfeited: session.youForfeited)
            timeRow(session.opponentName, elapsed: session.opponentElapsed, forfeited: session.opponentForfeited)
            HStack {
                Button("Rematch") { session.rematch() }
                    .buttonStyle(AppButtonStyle(kind: .primary))
                Button("Close") { session.close() }
                    .buttonStyle(AppButtonStyle(kind: .ghost))
            }
            .padding(.top, Theme.Space.s3)
            Text(session.status)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
        }
        .padding(Theme.Space.s8)
        .frame(maxWidth: 420)
        .glass(radius: Theme.Radius.xl, strong: true)
    }

    private var title: String {
        if session.youForfeited { return "You forfeited" }
        if session.opponentForfeited { return "You win" }
        if session.youWon == true { return "You win" }
        if session.youWon == false { return "\(session.opponentName) wins" }
        return "Race over"
    }

    private func timeRow(_ name: String, elapsed: Double?, forfeited: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(forfeited ? "Forfeit" : elapsed.map { SpeedrunClock.format($0) } ?? "Still going")
                .monospacedDigit()
                .font(Theme.font(Theme.Size.md, .semibold))
        }
    }
}
