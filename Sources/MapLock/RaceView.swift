import AppKit
import SwiftUI

@MainActor
final class RaceController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var session: RaceSession?
    private var closing = false
    var onClosed: (() -> Void)?
    var isShowing: Bool { window?.isVisible ?? false }
    var liveSession: RaceSession? { session }

    func show(session: RaceSession) {
        closing = false
        if let existing = self.session, existing !== session {
            existing.dropSocket()
        }
        self.session = session
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
        session?.dropSocket()
        session = nil
        window?.orderOut(nil)
        window?.contentView = nil
        onClosed?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let session, session.canOfferCancel {
            confirmLeave(session)
            return false
        }
        close()
        return false
    }

    private func confirmLeave(_ session: RaceSession) {
        guard let window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Cancel this race?"
        alert.informativeText = "The code will stop working."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel race")
        alert.addButton(withTitle: "Keep it open")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                if response == .alertFirstButtonReturn {
                    session.cancelAndClose()
                } else {
                    self.close()
                }
            }
        }
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

/// Copies a link, then shows a green Copied check. The same control is used
/// on the race window and the account race card.
struct CopyLinkButton: View {
    let text: String
    var height: CGFloat = 36
    @Binding var copyToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var hovering = false
    @State private var bounceToken = 0
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if copied {
                CopiedCheckmark(token: bounceToken, reduceMotion: reduceMotion)
                Text("Copied!")
            } else {
                Text("Copy")
            }
        }
        .font(Theme.font(Theme.Size.body, .semibold))
        .foregroundStyle(copied ? Theme.onTint : Color.white)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.s5)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(copied ? Theme.good : (hovering ? Theme.accentFillHover : Theme.accentFill))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: copied)
        .animation(reduceMotion ? nil : Theme.Motion.medium, value: hovering)
        .overlay(HitTarget(enabled: true, action: copy, hover: { hovering = $0 }))
        .accessibilityLabel(copied ? "Copied" : "Copy link")
        .accessibilityAddTraits(.isButton)
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyToken += 1
        if reduceMotion {
            copied = true
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { copied = true }
            let token = copyToken
            Task { @MainActor in
                await Task.yield()
                guard copied else { return }
                bounceToken = token
            }
        }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                copied = false
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { copied = false }
            }
        }
    }
}

/// Brief green wash on the race code. Scale is skipped when Reduce Motion is on.
struct CopyCodeHighlight: ViewModifier {
    var token: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = false
    @State private var fadeTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.good.opacity(highlighted ? 0.18 : 0))
            )
            .scaleEffect(reduceMotion || !highlighted ? 1 : 1.045)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
            .onChange(of: token) { _, newValue in
                guard newValue > 0 else { return }
                highlighted = true
                fadeTask?.cancel()
                fadeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    highlighted = false
                }
            }
    }
}

private struct CopiedCheckmark: View {
    var token: Int
    var reduceMotion: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .bold))
            .modifier(CopiedCheckEffect(token: token, reduceMotion: reduceMotion, scale: $scale))
    }
}

private struct CopiedCheckEffect: ViewModifier {
    var token: Int
    var reduceMotion: Bool
    @Binding var scale: CGFloat

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            moving(content)
        }
    }

    @ViewBuilder
    private func moving(_ content: Content) -> some View {
        if #available(macOS 14, *) {
            content.symbolEffect(.bounce, value: token)
        } else {
            content
                .scaleEffect(scale)
                .onChange(of: token) { _, _ in
                    scale = 1
                    withAnimation(.easeOut(duration: 0.12)) { scale = 1.1 }
                    withAnimation(.easeIn(duration: 0.12).delay(0.12)) { scale = 1 }
                }
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
    @State private var copyToken = 0
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            QuizView(session: session.quiz)
            if session.phase == "waiting" || session.phase == "countdown" || session.challengeEnd != nil {
                Theme.background.opacity(0.94).ignoresSafeArea()
                VStack(spacing: Theme.Space.s4) {
                    if let end = session.challengeEnd {
                        Text(end.message)
                            .font(Theme.font(Theme.Size.lg, .semibold))
                            .multilineTextAlignment(.center)
                        HStack(spacing: Theme.Space.s3) {
                            Button("Challenge again") { session.challengeAgain() }
                                .buttonStyle(AppButtonStyle(kind: .primary, height: 40))
                            Button("Go back") { session.giveUp() }
                                .buttonStyle(AppButtonStyle(kind: .ghost, height: 40))
                        }
                        if session.status != end.message {
                            Text(session.status)
                                .font(Theme.font(Theme.Size.sm))
                                .foregroundStyle(Theme.bad)
                                .multilineTextAlignment(.center)
                        }
                    } else if session.phase == "countdown" {
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
                            .modifier(CopyCodeHighlight(token: copyToken))
                        Text(session.ticket.webUrl)
                            .font(Theme.font(Theme.Size.sm))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        HStack(spacing: Theme.Space.s2) {
                            CopyLinkButton(text: session.ticket.webUrl, height: 36, copyToken: $copyToken)
                            RaceShareButton(text: session.ticket.webUrl)
                                .frame(width: 96, height: 36)
                        }
                        if session.isHost, !session.friendNames.isEmpty {
                            Menu {
                                ForEach(session.friendNames, id: \.self) { name in
                                    Button(name) { session.invite(username: name) }
                                }
                            } label: {
                                Text("Invite a friend")
                                    .font(Theme.font(Theme.Size.body, .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            if let note = session.inviteNote {
                                Text(note)
                                    .font(Theme.font(Theme.Size.sm))
                                    .foregroundStyle(Theme.text2)
                            }
                        }
                        if session.canOfferCancel {
                            HitButton { confirmCancel = true } label: {
                                Text("Cancel race")
                                    .font(Theme.font(Theme.Size.body, .semibold))
                                    .foregroundStyle(Theme.bad)
                                    .frame(height: 32)
                                    .padding(.horizontal, Theme.Space.s3)
                                    .contentShape(Rectangle())
                            }
                            .confirmationDialog("Cancel this race?", isPresented: $confirmCancel, titleVisibility: .visible) {
                                Button("Cancel race", role: .destructive) { session.cancelAndClose() }
                                Button("Keep it open", role: .cancel) {}
                            } message: {
                                Text("The code will stop working.")
                            }
                        }
                        if session.status != "Waiting for your friend" {
                            Text(session.status)
                                .font(Theme.font(Theme.Size.sm))
                                .foregroundStyle(Theme.bad)
                                .multilineTextAlignment(.center)
                        }
                    }
                    Text(SpeedrunKey.title(SpeedrunKey.make(
                        subject: QuizSubject(rawValue: session.ticket.subject) ?? .countries,
                        style: PracticeAnswerStyle(rawValue: session.ticket.style) ?? .clickMap,
                        place: session.scope.placeKey
                    )))
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                }
                .padding(Theme.Space.s6)
                .frame(maxWidth: 520)
            }
            if session.phase == "racing", session.youFinished {
                Theme.background.opacity(0.94).ignoresSafeArea()
                FinishedWaitingView(session: session)
            } else if session.phase == "racing" {
                VStack {
                    VStack(spacing: Theme.Space.s2) {
                        if session.opponentFinished, let time = session.opponentElapsed {
                            Text("\(session.opponentName) finished in \(SpeedrunClock.format(time))")
                                .font(Theme.font(Theme.Size.sm, .semibold))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, Theme.Space.s3)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.card))
                        }
                        opponentBar
                    }
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

private struct FinishedWaitingView: View {
    @ObservedObject var session: RaceSession

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: session.opponentFinished || session.opponentDnf)) { timeline in
            let running = session.opponentRunning(at: timeline.date)
            VStack(spacing: Theme.Space.s4) {
                Text(session.decided && session.youWon == true ? "You won!" : "You finished!")
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .foregroundStyle(Theme.text)
                if let time = session.youElapsed {
                    Text(SpeedrunClock.format(time))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
                Text(session.decided && session.youWon == true
                     ? "\(session.opponentName) can still finish."
                     : "Waiting for \(session.opponentName)")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                VStack(alignment: .leading, spacing: Theme.Space.s2) {
                    HStack {
                        Text(session.opponentName)
                            .font(Theme.font(Theme.Size.sm, .semibold))
                        Spacer()
                        Text(session.opponentDnf ? "DNF" : SpeedrunClock.format(running))
                            .font(Theme.font(Theme.Size.sm, .semibold))
                            .monospacedDigit()
                    }
                    Text("\(session.opponentFound) of \(session.opponentTotal) countries")
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                    ProgressView(value: Double(session.opponentFound), total: Double(max(session.opponentTotal, 1)))
                        .tint(Theme.accent)
                }
                .padding(Theme.Space.s4)
                .frame(maxWidth: 360)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.card)
                )
                Button("Leave") { session.leaveWaiting() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 36))
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 460)
        }
    }
}

private struct RaceResultView: View {
    @ObservedObject var session: RaceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            if won && !reduceMotion {
                RaceGlow()
                    .allowsHitTesting(false)
            }
            VStack(spacing: Theme.Space.s4) {
                Text(headline)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if let margin {
                    Text(margin)
                        .font(Theme.font(Theme.Size.sm, .semibold))
                        .foregroundStyle(Theme.text2)
                }
                HStack(alignment: .top, spacing: Theme.Space.s4) {
                    playerColumn(name: "You", elapsed: session.youElapsed, raw: session.youRaw,
                                 misses: session.youMisses, skips: session.youSkips,
                                 found: session.youFound, dnf: session.youDnf, forfeited: session.youForfeited,
                                 best: session.isPersonalBest)
                    playerColumn(name: session.opponentName, elapsed: session.opponentElapsed, raw: session.opponentRaw,
                                 misses: session.opponentMisses, skips: session.opponentSkips,
                                 found: session.opponentFound, dnf: session.opponentDnf, forfeited: session.opponentForfeited,
                                 best: false)
                }
                VStack(spacing: Theme.Space.s2) {
                    Button("Rematch") { session.rematch() }
                        .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
                    HStack(spacing: Theme.Space.s2) {
                        Button("Change region") { session.changeRegion() }
                            .buttonStyle(AppButtonStyle(kind: .ghost, height: 36, fullWidth: true))
                        Button("Done") { session.close() }
                            .buttonStyle(AppButtonStyle(kind: .ghost, height: 36, fullWidth: true))
                    }
                }
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 520)
            .glass(radius: Theme.Radius.xl, strong: true)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .opacity(shown || reduceMotion ? 1 : 0)
        }
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { shown = true }
            }
        }
    }

    private var won: Bool { session.youWon == true && !session.tie }

    private var headline: String {
        if session.tie { return "Tie" }
        if session.youForfeited { return "You lost" }
        if session.opponentForfeited || (session.youWon == true && session.reason == "forfeit") { return "Won by forfeit" }
        if session.youDnf { return "DNF" }
        if session.youWon == true { return "You won!" }
        if session.youWon == false { return "You lost" }
        return "Race ended"
    }

    private var margin: String? {
        guard !session.tie, session.reason == "time" || session.reason == nil,
              let you = session.youElapsed, let them = session.opponentElapsed,
              !session.youDnf, !session.opponentDnf, !session.youForfeited, !session.opponentForfeited else { return nil }
        let gap = abs(you - them)
        return String(format: "Won by %.1fs", gap)
    }

    private func playerColumn(name: String, elapsed: Double?, raw: Double?, misses: Int, skips: Int,
                              found: Int, dnf: Bool, forfeited: Bool, best: Bool) -> some View {
        VStack(spacing: Theme.Space.s2) {
            RaceInitials(name: name)
            Text(name)
                .font(Theme.font(Theme.Size.sm, .semibold))
                .lineLimit(1)
            Text(forfeited ? "Forfeit" : dnf ? "DNF" : elapsed.map { SpeedrunClock.format($0) } ?? "-")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
            if best {
                Text("Personal best")
                    .font(Theme.font(Theme.Size.xs, .bold))
                    .foregroundStyle(Theme.good)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.good.opacity(0.15)))
            }
            VStack(alignment: .leading, spacing: 2) {
                detail("Raw", raw.map { SpeedrunClock.format($0) } ?? "-")
                detail("Misses", "\(misses) × +3s")
                detail("Skips", "\(skips) × +10s")
                detail("Accuracy", accuracy(found: found, misses: misses))
            }
            .font(Theme.font(Theme.Size.xs))
            .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
    }

    private func accuracy(found: Int, misses: Int) -> String {
        let percent = SpeedrunRules.accuracy(countries: found, misses: misses) * 100
        return String(format: "%.0f%%", percent)
    }
}

private struct RaceInitials: View {
    let name: String

    var body: some View {
        Text(initials)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.accentFill))
    }

    private var initials: String {
        let parts = name.split { $0 == "_" || $0 == " " || $0 == "-" }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        let letters = name.filter(\.isLetter)
        let raw = String(letters.prefix(2)).uppercased()
        return raw.isEmpty ? "?" : raw
    }
}

private struct RaceGlow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<14 {
                    let travel = (t * 36 + Double(i * 28)).truncatingRemainder(dividingBy: Double(size.height + 20))
                    let x = CGFloat((i * 53) % max(Int(size.width), 1))
                    let rect = CGRect(x: x, y: CGFloat(travel) - 10, width: 7, height: 9)
                    let color = i % 2 == 0 ? Theme.good : Theme.accent
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.85)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
