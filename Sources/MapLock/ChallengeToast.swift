import AppKit
import SwiftUI

enum RaceInviteClock {
    static let ttl: TimeInterval = 10 * 60

    static func secondsLeft(_ createdAtMs: Int, now: Date = Date()) -> TimeInterval {
        let start = Double(createdAtMs) / 1000
        return ttl - (now.timeIntervalSince1970 - start)
    }

    static func fractionLeft(_ createdAtMs: Int, now: Date = Date()) -> Double {
        min(1, max(0, secondsLeft(createdAtMs, now: now) / ttl))
    }
}

/// Challenge cards pinned to the bottom-right of whichever window is in front.
@MainActor
final class ChallengeToastController: ObservableObject {
    @Published private(set) var invites: [RaceInvite] = []
    @Published private(set) var flashes: [String] = []

    var onAccept: (RaceInvite) -> Void = { _ in }
    var onDecline: (RaceInvite) -> Void = { _ in }

    private var primed = false
    private var previous: [RaceInvite] = []
    private var handled: Set<String> = []
    private var locallyExpired: Set<String> = []
    private var sounded: Set<String> = []
    private var panel: NSWindow?
    private var host: NSHostingView<ChallengeToastColumn>?
    private var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func noteHandled(_ id: String) {
        handled.insert(id)
    }

    func sync(_ next: [RaceInvite], live: Bool) {
        if !live {
            primed = false
            previous = []
            invites = []
            flashes = []
            handled = []
            locallyExpired = []
            reposition()
            return
        }
        let visible = next.filter { !locallyExpired.contains($0.id) }
        let nextIds = Set(visible.map(\.id))
        for old in previous where !nextIds.contains(old.id) && !locallyExpired.contains(old.id) {
            guard !handled.contains(old.id) else { continue }
            if RaceInviteClock.secondsLeft(old.createdAt) < 3 { continue }
            if flashes.contains(old.id) { continue }
            flashes.append(old.id)
            let id = old.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self else { return }
                self.flashes.removeAll { $0 == id }
                self.reposition()
            }
        }
        if !primed {
            primed = true
            if visible.isEmpty || !NSApp.isActive {
                for invite in visible { sounded.insert(invite.id) }
            }
        }
        for invite in visible where !sounded.contains(invite.id) {
            sounded.insert(invite.id)
            if NSApp.isActive { AnswerSound.playSoft() }
        }
        handled = handled.intersection(nextIds.union(Set(flashes)))
        previous = visible
        invites = visible
        updateEsc()
        reposition()
    }

    private var escMonitor: Any?

    private func updateEsc() {
        if invites.isEmpty {
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
            return
        }
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if NSApp.keyWindow?.isSheet == true { return event }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return event }
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let invite = self.invites.first else { return false }
                self.decline(invite)
                return true
            }
            return taken ? nil : event
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ChallengeToastColumn(model: self))
        hosting.sizingOptions = [.intrinsicContentSize]
        window.contentView = hosting
        panel = window
        host = hosting
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            }
            observers.append(token)
        }
    }

    private func reposition() {
        ensurePanel()
        guard let panel else { return }
        if NSApp.keyWindow === panel, parent != nil {
            layout()
            return
        }
        let visible = !invites.isEmpty || !flashes.isEmpty
        guard visible, let window = targetWindow() else {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            parent = nil
            return
        }
        if parent !== window {
            parent?.removeChildWindow(panel)
            panel.level = window.level
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        layout()
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    private func layout() {
        guard let panel, let host, let parent else { return }
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let width = max(fit.width, 300)
        let height = max(fit.height, 40)
        let frame = parent.frame
        let margin: CGFloat = 24
        var y = frame.minY + margin
        if y + height > frame.maxY - 8 { y = max(frame.minY + 8, frame.maxY - height - 8) }
        let origin = NSPoint(x: frame.maxX - width - margin, y: y)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
    }

    func anchorWindow() -> NSWindow? { parent }

    private func targetWindow() -> NSWindow? {
        let usable: (NSWindow) -> Bool = { window in
            window !== self.panel && window.isVisible && window.contentView != nil
        }
        if let key = NSApp.keyWindow, usable(key) { return key }
        if let main = NSApp.mainWindow, usable(main) { return main }
        return NSApp.windows.first(where: usable)
    }

    fileprivate func expire(_ invite: RaceInvite) {
        guard invites.contains(where: { $0.id == invite.id }) else { return }
        locallyExpired.insert(invite.id)
        noteHandled(invite.id)
        invites.removeAll { $0.id == invite.id }
        previous.removeAll { $0.id == invite.id }
        reposition()
    }

    fileprivate func accept(_ invite: RaceInvite) {
        onAccept(invite)
    }

    fileprivate func decline(_ invite: RaceInvite) {
        noteHandled(invite.id)
        onDecline(invite)
    }
}

private struct ChallengeToastColumn: View {
    @ObservedObject var model: ChallengeToastController

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.s3) {
            ForEach(model.flashes, id: \.self) { _ in
                Text("Challenge cancelled")
                    .font(Theme.font(Theme.Size.sm, .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 320, alignment: .leading)
                    .padding(Theme.Space.s4)
                    .background(toastPlate)
            }
            ForEach(Array(model.invites.reversed())) { invite in
                ChallengeCard(invite: invite) {
                    model.accept(invite)
                } onDecline: {
                    model.decline(invite)
                } onExpire: {
                    model.expire(invite)
                }
            }
        }
        .padding(Theme.Space.s2)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var toastPlate: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)
    }
}

private struct ChallengeCard: View {
    let invite: RaceInvite
    var onAccept: () -> Void
    var onDecline: () -> Void
    var onExpire: () -> Void
    @State private var arrived = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = RaceInviteClock.fractionLeft(invite.createdAt, now: context.date)
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                HStack(alignment: .top, spacing: Theme.Space.s3) {
                    Text(initials(invite.fromUsername))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.accentFill))
                    VStack(alignment: .leading, spacing: Theme.Space.s1) {
                        Text(invite.fromUsername)
                            .font(Theme.font(Theme.Size.body, .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text("challenged you to a race")
                            .font(Theme.font(Theme.Size.sm))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                        Text(invite.challengeLine)
                            .font(Theme.font(Theme.Size.sm, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.s2)
                    Button(action: onDecline) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text3)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Decline")
                }
                Capsule()
                    .fill(Theme.fill3)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: max(4, geo.size.width * left))
                        }
                    }
                HStack(spacing: Theme.Space.s2) {
                    ToastAction(title: "Accept", prominent: true, action: onAccept)
                    ToastAction(title: "Decline", prominent: false, action: onDecline)
                }
            }
            .padding(Theme.Space.s4)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)
            )
            .opacity(arrived ? 1 : 0)
            .offset(x: arrived ? 0 : 16, y: arrived ? 0 : 20)
            .onAppear {
                withAnimation(.easeOut(duration: 0.28)) { arrived = true }
            }
            .task(id: invite.id) {
                let delay = RaceInviteClock.secondsLeft(invite.createdAt)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                onExpire()
            }
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split { $0 == "_" || $0 == " " || $0 == "-" }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        let letters = name.filter(\.isLetter)
        let raw = String(letters.prefix(2)).uppercased()
        return raw.isEmpty ? "?" : raw
    }
}

private struct ToastAction: View {
    let title: String
    let prominent: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(fill)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if prominent {
            return hovering ? Theme.accentFillHover : Theme.accentFill
        }
        return hovering ? Theme.fill3 : Theme.fill2
    }
}
