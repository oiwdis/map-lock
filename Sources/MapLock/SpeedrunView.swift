import SwiftUI

/// Speedrun window: a running clock, the region map, and a finish card.
struct SpeedrunView: View {
    @ObservedObject var session: SpeedrunSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var dialogUp: Bool { session.phase == .finished || session.confirmingEnd }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let country = session.currentCountry, session.phase == .asking {
                SpeedrunQuestionView(session: session, country: country)
                    .blur(radius: dialogUp ? 18 : 0)
                    .allowsHitTesting(!dialogUp)
                    .accessibilityHidden(dialogUp)
            }

            if session.phase == .asking {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("End speedrun") { session.confirmingEnd = true }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.trailing, Theme.Space.s5)
                .padding(.bottom, Theme.Space.s4)
                .opacity(session.confirmingEnd ? 0 : 1)
            }

            if session.confirmingEnd {
                SpeedrunScrim()
                SpeedrunEndConfirm(session: session)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }

            if session.phase == .finished {
                SpeedrunScrim()
                SpeedrunFinishedView(session: session)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .foregroundStyle(Theme.text)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : Theme.Motion.slow, value: dialogUp)
        .onAppear {
            session.startClockIfNeeded()
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Theme.Motion.slow) { appeared = true }
            }
        }
    }
}

private struct SpeedrunScrim: View {
    var body: some View {
        Theme.scrim.ignoresSafeArea()
    }
}

private struct SpeedrunQuestionView: View {
    @ObservedObject var session: SpeedrunSession
    let country: Country
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: Theme.Space.s4) {
                header
                    .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
                Text(country.name)
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.text)
                    .modifier(ShakeEffect(shakes: CGFloat(session.shakeCount)))
                    .animation(reduceMotion ? nil : .linear(duration: 0.4), value: session.shakeCount)
                    .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
                    .frame(minHeight: 44)
                mapCard
                    .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
            }
            .padding(.horizontal, Theme.Space.s8)
            .padding(.top, Theme.Space.s6)
            .padding(.bottom, Theme.Space.s10)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s3) {
            Text("Speedrun")
                .font(Theme.font(Theme.Size.md, .bold))
                .kerning(-0.3)
            Text(session.progressText)
                .font(Theme.font(Theme.Size.body, .medium))
                .foregroundStyle(Theme.text2)
                .monospacedDigit()
            if let chip = session.answerChip {
                AnswerChipBanner(chip: chip, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: Theme.Space.s3)
            SpeedrunClockReadout(session: session)
            Pill {
                Image(systemName: "map").foregroundStyle(Theme.text2)
                Text(session.scopeTitle)
            }
        }
        .frame(minHeight: 36)
    }

    private var mapCard: some View {
        ClickMapView(
            world: session.world,
            target: country,
            state: .asking,
            clicked: nil,
            enabled: true,
            mapScope: session.scope,
            revealTarget: false,
            speedrunCue: session.burst,
            found: session.found,
            cursorPrompt: cursorPrompt,
            cursorPromptSuspended: session.confirmingEnd
        ) { name in
            session.click(name)
        }
        .aspectRatio(clickAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.mapFrame, lineWidth: 1)
        )
        .shadow(color: Theme.shadow, radius: 8, x: 0, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cursorPrompt: MapCursorPrompt? {
        guard AppSettings().cursorPrompt else { return nil }
        let note: String?
        let good: Bool
        if let chip = session.answerChip {
            note = chip.right ? "Correct!" : "Wrong"
            good = chip.right
        } else {
            note = nil
            good = false
        }
        return MapCursorPrompt.click(subject: .countries, country: country.name, detail: country.name,
                                     note: note, noteIsGood: good)
    }

    private var clickAspect: Double {
        MapViews.clickAspect(scope: session.scope, world: session.world)
    }
}

/// Live `mm:ss.t` readout. Tenths update while the run is going, then freeze.
private struct SpeedrunClockReadout: View {
    @ObservedObject var session: SpeedrunSession

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !session.clockRunning)) { timeline in
            Text(session.timeText(at: timeline.date))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .accessibilityLabel("Time \(session.timeText(at: timeline.date))")
        }
    }
}

private struct SpeedrunEndConfirm: View {
    @ObservedObject var session: SpeedrunSession

    var body: some View {
        VStack(spacing: 0) {
            Text("End this speedrun?")
                .font(Theme.font(Theme.Size.md, .semibold))
            Text("This run will not be saved.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .padding(.top, Theme.Space.s1)
                .padding(.bottom, Theme.Space.s5)
            HStack(spacing: Theme.Space.s2) {
                Button("Keep going") { session.confirmingEnd = false }
                    .buttonStyle(AppButtonStyle(kind: .ghost, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                Button("End") { session.endWithoutSaving() }
                    .buttonStyle(AppButtonStyle(kind: .danger, fullWidth: true))
            }
        }
        .padding(Theme.Space.s6)
        .frame(maxWidth: 340)
        .glass(radius: Theme.Radius.xl, strong: true)
        .padding(Theme.Space.s6)
    }
}

private struct SpeedrunFinishedView: View {
    @ObservedObject var session: SpeedrunSession

    var body: some View {
        VStack(spacing: 0) {
            Text("SPEEDRUN COMPLETE")
                .font(Theme.font(Theme.Size.xs, .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, Theme.Space.s3)
            Text(session.total == 0 ? "Nothing to ask" : session.finalTimeText)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .kerning(-1)
                .monospacedDigit()
                .foregroundStyle(session.isNewBest ? Theme.accent : Theme.text)

            if session.total == 0 {
                Text("No countries in this place.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                    .padding(.top, Theme.Space.s2)
            } else {
                if session.isNewBest {
                    Text("New best")
                        .font(Theme.font(Theme.Size.sm, .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Space.s3)
                        .padding(.vertical, Theme.Space.s1)
                        .background(
                            Capsule().fill(Theme.accent.opacity(0.14))
                        )
                        .padding(.top, Theme.Space.s3)
                        .accessibilityAddTraits(.isHeader)
                }

                Text(session.scopeTitle)
                    .font(Theme.font(Theme.Size.md, .semibold))
                    .padding(.top, Theme.Space.s3)

                HStack(spacing: Theme.Space.s2) {
                    Pill {
                        Image(systemName: "xmark").foregroundStyle(Theme.bad)
                        Text(session.missesText).monospacedDigit()
                    }
                    Pill {
                        Image(systemName: "target").foregroundStyle(Theme.good)
                        Text(session.accuracyText).monospacedDigit()
                    }
                }
                .padding(.top, Theme.Space.s4)

                HStack(spacing: Theme.Space.s2) {
                    Image(systemName: "timer")
                        .foregroundStyle(session.isNewBest ? Theme.accent : Theme.text2)
                    Text("Personal best")
                        .foregroundStyle(Theme.text2)
                    Text(session.personalBestText)
                        .font(Theme.font(Theme.Size.body, .semibold))
                        .foregroundStyle(session.isNewBest ? Theme.accent : Theme.text)
                        .monospacedDigit()
                }
                .padding(.top, Theme.Space.s3)
            }

            Button("Close") { session.done() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Space.s6)
        }
        .padding(Theme.Space.s8)
        .frame(maxWidth: 400)
        .glass(radius: Theme.Radius.xl, strong: true)
        .padding(Theme.Space.s6)
    }
}
