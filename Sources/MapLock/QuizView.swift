import SwiftUI

/// The full screen quiz overlay.
struct QuizView: View {
    @ObservedObject var session: QuizSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var dialogUp: Bool { session.phase == .finished || session.confirmingSkip }

    var body: some View {
        ZStack {
            Backdrop()

            if let question = session.current {
                QuestionView(session: session, question: question)
                    .blur(radius: dialogUp ? 18 : 0)
                    .allowsHitTesting(!dialogUp)
            }

            // Quiet emergency exit, bottom right corner.
            if session.phase != .finished {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Emergency skip") { session.confirmingSkip = true }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.trailing, Theme.Space.s5)
                .padding(.bottom, Theme.Space.s4)
                .opacity(session.confirmingSkip ? 0 : 1)
            }

            if session.confirmingSkip {
                Scrim()
                SkipConfirmView(session: session)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }

            if session.phase == .finished {
                Scrim()
                FinishedView(session: session)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .foregroundStyle(Theme.text)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : Theme.Motion.slow, value: dialogUp)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Theme.Motion.slow) { appeared = true }
            }
        }
    }
}

private struct Scrim: View {
    var body: some View {
        Theme.scrim
            .ignoresSafeArea()
            .transition(.opacity)
    }
}

// MARK: Question

private struct QuestionView: View {
    @ObservedObject var session: QuizSession
    let question: Question
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.s4) {
            header
            mapCard
            answerArea
                // Click questions only need the name and the result line, so the map gets more room.
                .frame(minHeight: question.kind == .click ? 120 : 190, alignment: .top)
        }
        .padding(.horizontal, Theme.Space.s8)
        .padding(.top, Theme.Space.s6)
        .padding(.bottom, Theme.Space.s10)
        .onAppear { focusFieldSoon() }
        .onChange(of: session.index) { _, _ in focusFieldSoon() }
    }

    private func focusFieldSoon() {
        guard question.kind == .typing else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            fieldFocused = true
        }
    }

    // Header: title + "2 of 5", progress bar, round and streak pills.
    private var header: some View {
        ZStack {
            HStack(spacing: Theme.Space.s3) {
                Text("Map Lock")
                    .font(Theme.font(Theme.Size.md, .bold))
                    .kerning(-0.3)
                Text(session.progressText)
                    .font(Theme.font(Theme.Size.body, .medium))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                Spacer()
                Pill {
                    Text(session.roundText).monospacedDigit()
                }
                Pill {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.warn)
                    Text("\(session.streak)").monospacedDigit()
                }
            }
            ProgressSteps(total: session.total, results: session.results, current: session.index)
        }
        .frame(height: 32)
    }

    private var mapCard: some View {
        Group {
            if question.kind == .click {
                ClickMapView(
                    world: session.world,
                    target: question.target,
                    state: session.targetState,
                    clicked: session.clicked,
                    enabled: session.phase == .asking
                ) { name in
                    session.click(name)
                }
                // Card shaped like the region, so the land fills it (like Seterra).
                .aspectRatio(MapViews.clickAspect(for: question.target, world: session.world), contentMode: .fit)
            } else {
                MapView(world: session.world, target: question.target, state: session.targetState)
            }
        }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                    .strokeBorder(Theme.mapFrame, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Pill {
                    Image(systemName: "map").foregroundStyle(Theme.text2)
                    Text(question.kind == .click ? MapViews.regionTitle(for: question.target)
                                                 : MapViews.title(for: question.target))
                }
                .padding(Theme.Space.s4)
                // Clicks go through to the map.
                .allowsHitTesting(false)
            }
            .shadow(color: Theme.shadow, radius: 12, x: 0, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answerArea: some View {
        VStack(spacing: Theme.Space.s3) {
            Text(promptText)
                .font(Theme.font(Theme.Size.body, .medium))
                .foregroundStyle(Theme.text2)

            switch question.kind {
            case .choice: choiceGrid
            case .typing: typingArea
            case .click: clickArea
            }

            feedbackRow
        }
    }

    private var promptText: String {
        switch question.kind {
        case .choice: return "Which country is highlighted?"
        case .typing: return "Type the name, then press Return"
        case .click: return "Click this country on the map"
        }
    }

    // MARK: Click the country

    private var clickArea: some View {
        HStack(spacing: Theme.Space.s4) {
            Text(question.target.name)
                .font(Theme.font(Theme.Size.xl, .bold))
                .kerning(-0.4)
                .foregroundStyle(clickNameColor)
                .modifier(ShakeEffect(shakes: CGFloat(session.shakeCount)))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: session.shakeCount)
            if session.phase == .asking {
                Button("I don't know") { session.giveUp() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var clickNameColor: Color {
        guard session.phase == .answered else { return Theme.text }
        return session.lastWasRight ? Theme.good : Theme.bad
    }

    // MARK: Multiple choice

    private var choiceGrid: some View {
        let options = question.options
        return VStack(spacing: Theme.Space.s3) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: Theme.Space.s3) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        if i < options.count {
                            ChoiceButton(
                                title: options[i],
                                number: i + 1,
                                state: choiceState(options[i]),
                                reduceMotion: reduceMotion
                            ) {
                                session.choose(options[i])
                            }
                            .disabled(session.phase != .asking)
                        }
                    }
                }
            }
        }
        // Fresh buttons for each question, so the feedback motion never plays backwards.
        .id(session.index)
    }

    private func choiceState(_ option: String) -> ChoiceButton.Look {
        guard session.phase == .answered else { return .normal }
        if option == question.target.name { return .right }
        if option == session.chosen { return .wrong }
        return .dim
    }

    // MARK: Typing

    private var typingArea: some View {
        VStack(spacing: Theme.Space.s2) {
            HStack(spacing: Theme.Space.s2) {
                TextField("", text: $session.typed, prompt: Text("Type the country name").foregroundColor(Theme.text3))
                    .textFieldStyle(.plain)
                    .font(Theme.font(Theme.Size.lg, .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.s5)
                    // Shrinks on small screens instead of pushing the Check button off.
                    .frame(minWidth: 200, maxWidth: 440)
                    .frame(height: 56)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(fieldFill)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(fieldBorder, lineWidth: fieldFocused && session.phase == .asking ? 2 : 1)
                    )
                    .modifier(ShakeEffect(shakes: CGFloat(session.shakeCount)))
                    .animation(reduceMotion ? nil : .linear(duration: 0.4), value: session.shakeCount)
                    .focused($fieldFocused)
                    .autocorrectionDisabled(true)
                    .onSubmit { session.submitTyped() }
                    .disabled(session.phase != .asking)

                if session.phase == .asking {
                    Button("Check") { session.submitTyped() }
                        .buttonStyle(AppButtonStyle(kind: .primary, height: 56))
                }
            }
            if session.phase == .asking {
                Button("I don't know") { session.giveUp() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var fieldFill: Color {
        guard session.phase == .answered else { return Theme.glass }
        return session.lastWasRight ? Theme.goodBG : Theme.badBG
    }

    private var fieldBorder: Color {
        if session.phase == .answered { return session.lastWasRight ? Theme.good : Theme.bad }
        return fieldFocused ? Theme.accent.opacity(0.6) : Theme.hairline2
    }

    // MARK: Feedback

    private var feedbackRow: some View {
        HStack(spacing: Theme.Space.s4) {
            if session.phase == .answered {
                Text(session.feedback)
                    .font(Theme.font(Theme.Size.md, .semibold))
                    .foregroundStyle(session.lastWasRight ? Theme.good : Theme.bad)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                Button {
                    session.next()
                } label: {
                    HStack(spacing: Theme.Space.s2) {
                        Text(session.isLastQuestion ? "See my score" : "Next")
                        Image(systemName: "return")
                            .font(Theme.font(Theme.Size.xs, .semibold))
                            .opacity(0.7)
                    }
                }
                .buttonStyle(AppButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 44)
        .animation(reduceMotion ? nil : Theme.Motion.medium, value: session.phase == .answered)
    }
}

/// Segmented progress: one bar per question, green or red once answered.
private struct ProgressSteps: View {
    let total: Int
    let results: [Bool]
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(color(i))
                    .frame(minWidth: 6, maxWidth: 28)
                    .frame(height: 6)
            }
        }
        .animation(Theme.Motion.slow, value: results)
    }

    private func color(_ i: Int) -> Color {
        if i < results.count { return results[i] ? Theme.good : Theme.bad }
        if i == current { return Theme.text }
        return Theme.fill2
    }
}

/// One of the four answers: number badge, name, green pulse or red shake.
private struct ChoiceButton: View {
    enum Look { case normal, right, wrong, dim }

    let title: String
    let number: Int
    let look: Look
    let reduceMotion: Bool
    let action: () -> Void

    init(title: String, number: Int, state: Look, reduceMotion: Bool, action: @escaping () -> Void) {
        self.title = title
        self.number = number
        self.look = state
        self.reduceMotion = reduceMotion
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s3) {
                KeyBadge(text: "\(number)", tint: badgeTint)
                Text(title)
                    .font(Theme.font(Theme.Size.md, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s4)
            // Up to 340 wide, narrower when the window is small.
            .frame(minWidth: 0, maxWidth: 340)
            .frame(height: 52)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(fill)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .offset(y: hovering && look == .normal && !reduceMotion ? -1 : 0)
        .opacity(look == .dim ? 0.45 : 1)
        // Green pulse when this is the answer, red shake when it was the wrong pick.
        .modifier(PulseEffect(pulses: look == .right ? 1 : 0))
        .modifier(ShakeEffect(shakes: look == .wrong ? 1 : 0))
        .animation(reduceMotion ? nil : Theme.Motion.slow, value: look)
        .animation(Theme.Motion.fast, value: hovering)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch look {
        case .right: return Theme.goodBG
        case .wrong: return Theme.badBG
        case .normal: return hovering ? Theme.fill3 : Theme.glass
        case .dim: return Theme.glass
        }
    }

    private var borderColor: Color {
        switch look {
        case .right: return Theme.good
        case .wrong: return Theme.bad
        default: return Theme.hairline2
        }
    }

    private var badgeTint: Color? {
        switch look {
        case .right: return Theme.good
        case .wrong: return Theme.bad
        default: return nil
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

// MARK: Dialogs

private struct SkipConfirmView: View {
    @ObservedObject var session: QuizSession

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.warnBG)
                .frame(width: 44, height: 44)
                .overlay(
                    Text("!")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(Theme.warn)
                )
            Text("Skip today's quiz?")
                .font(Theme.font(Theme.Size.md, .semibold))
                .padding(.top, Theme.Space.s3)
            Text("Are you sure? Your streak will not count today.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Space.s1)
                .padding(.bottom, Theme.Space.s5)
            HStack(spacing: Theme.Space.s2) {
                Button("Keep going") { session.confirmingSkip = false }
                    .buttonStyle(AppButtonStyle(kind: .ghost, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                Button("Skip") { session.skip() }
                    .buttonStyle(AppButtonStyle(kind: .danger, fullWidth: true))
            }
        }
        .padding(Theme.Space.s6)
        .frame(maxWidth: 340)
        .glass(radius: Theme.Radius.xl, strong: true)
        .padding(Theme.Space.s6)
    }
}

private struct FinishedView: View {
    @ObservedObject var session: QuizSession

    var body: some View {
        VStack(spacing: 0) {
            ScoreRing(fraction: session.scoreFraction, text: "\(session.score)/\(session.askedCount)")
                .frame(width: 200, height: 200)
                .padding(.bottom, Theme.Space.s5)

            Text(session.askedCount == 0 ? "Nothing to ask" : "Unlocked!")
                .font(Theme.font(Theme.Size.xl, .bold))
                .kerning(-0.5)
            Text(message)
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Space.s2)
                .padding(.bottom, Theme.Space.s4)

            HStack(spacing: Theme.Space.s2) {
                Pill {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.warn)
                    Text(session.streak == 1 ? "1 day streak" : "\(session.streak) day streak")
                }
                Pill {
                    Text(session.roundText).monospacedDigit()
                }
            }
            .padding(.bottom, Theme.Space.s6)

            Button("Back to desktop") { session.done() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.s8)
        .frame(maxWidth: 380)
        .glass(radius: Theme.Radius.xl, strong: true)
        .padding(Theme.Space.s6)
    }

    private var message: String {
        let total = session.askedCount
        if total == 0 { return "Turn on a region in the menu bar." }
        if session.score == total { return "You got all \(total) right. Nice work!" }
        return "You got \(session.score) of \(total) right. Missed ones will come back soon."
    }
}

/// Score ring that fills in when it appears.
private struct ScoreRing: View {
    let fraction: Double
    let text: String
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.fill2, lineWidth: 12)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Theme.good, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text)
                .font(.system(size: 52, weight: .bold))
                .kerning(-1)
                .monospacedDigit()
        }
        .padding(6)
        .onAppear {
            if reduceMotion {
                shown = fraction
            } else {
                withAnimation(Theme.Motion.ease(0.9).delay(0.15)) { shown = fraction }
            }
        }
    }
}
