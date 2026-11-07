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
            Theme.background.ignoresSafeArea()
            if session.phase == "finished" {
                RaceResultView(session: session)
            } else if session.phase == "countdown" {
                Text(session.countdown.map(String.init) ?? "1")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else if session.phase == "racing", let country = session.currentCountry {
                RaceMapView(session: session, country: country)
            } else {
                VStack(spacing: Theme.Space.s3) {
                    Text(session.status)
                        .font(Theme.font(Theme.Size.md, .semibold))
                    Text("\(session.scope.title) · \(session.total) countries")
                        .foregroundStyle(Theme.text2)
                }
            }
        }
        .foregroundStyle(Theme.text)
    }
}

private struct RaceMapView: View {
    @ObservedObject var session: RaceSession
    let country: Country
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.s3) {
            HStack {
                Text(session.progressText).monospacedDigit().foregroundStyle(Theme.text2)
                Spacer()
                TimelineView(.animation(minimumInterval: 0.1, paused: !session.clockRunning)) { timeline in
                    Text(session.timeText(at: timeline.date))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            opponentBar
            ClickMapView(
                world: session.world,
                target: country,
                state: session.flashCountry == nil ? .asking : .wrong,
                clicked: session.flashCountry,
                enabled: session.canClick,
                mapScope: session.scope,
                revealTarget: false
            ) { name in
                session.click(name)
            }
            .aspectRatio(session.scope.serverRegion == "world" ? 2 : MapViews.clickAspect(for: country, world: session.world), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            Text(country.name)
                .font(Theme.font(Theme.Size.xl, .bold))
                .modifier(ShakeEffect(shakes: CGFloat(session.shakeCount)))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: session.shakeCount)
            Button("Forfeit") { session.forfeit() }
                .buttonStyle(AppButtonStyle(kind: .danger))
        }
        .padding(Theme.Space.s6)
    }

    private var opponentBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.opponentName)
                    .font(Theme.font(Theme.Size.sm, .semibold))
                Spacer()
                Text("\(session.opponentFound) of \(session.opponentTotal) · \(session.opponentMisses) misses")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
            }
            ProgressView(value: Double(session.opponentFound), total: Double(max(session.opponentTotal, 1)))
                .tint(Theme.accent)
        }
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
        if session.youWon == true { return "You finished first" }
        if session.youWon == false { return "\(session.opponentName) finished first" }
        return "Race over"
    }

    private func timeRow(_ name: String, elapsed: Double?, forfeited: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(forfeited ? "Forfeit" : elapsed.map { SpeedrunClock.format($0) } ?? "-")
                .monospacedDigit()
                .font(Theme.font(Theme.Size.md, .semibold))
        }
    }
}
