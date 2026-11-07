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
                        Button(session.locksScreen ? "Emergency skip" : "End practice") { session.confirmingSkip = true }
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
        GeometryReader { geo in
            VStack(spacing: Theme.Space.s4) {
                header
                    .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
                if question.subject == .flags, let flag = question.flagEmoji {
                    Text(flag)
                        .font(.system(size: 96))
                        .padding(.vertical, Theme.Space.s2)
                        .accessibilityLabel("Flag")
                }
                if question.subject != .flags || question.kind == .click {
                    mapCard
                        .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
                }
                answerArea
                    // Click questions only need the name and the result line, so the map gets more room.
                    .frame(minHeight: question.kind == .click ? 100 : 170, alignment: .top)
                    .frame(maxWidth: min(geo.size.width - Theme.Space.s8 * 2, 1100))
            }
            .padding(.horizontal, Theme.Space.s8)
            .padding(.top, Theme.Space.s6)
            .padding(.bottom, Theme.Space.s10)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear {
            focusFieldSoon()
            session.noteSpeedrunVisible()
        }
        .onChange(of: session.index) { _, _ in
            focusFieldSoon()
            session.noteSpeedrunVisible()
        }
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
            if session.isSpeedrun {
                speedrunHeader
            } else {
                HStack(spacing: Theme.Space.s3) {
                    Text("Map Lock")
                        .font(Theme.font(Theme.Size.md, .bold))
                        .kerning(-0.3)
                    Text(session.progressText)
                        .font(Theme.font(Theme.Size.body, .medium))
                        .foregroundStyle(Theme.text2)
                        .monospacedDigit()
                    if let chip = session.answerChip {
                        AnswerChipBanner(chip: chip, reduceMotion: reduceMotion)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
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
        }
        .animation(.easeOut(duration: 0.2), value: session.answerChip?.token)
        .frame(minHeight: session.isSpeedrun ? 40 : 32)
    }

    private var speedrunHeader: some View {
        HStack(spacing: Theme.Space.s3) {
            Text(session.progressText)
                .font(Theme.font(Theme.Size.body, .semibold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .modifier(PulseEffect(pulses: reduceMotion ? 0 : CGFloat(session.pulseCount)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: session.pulseCount)
            if let chip = session.answerChip {
                AnswerChipBanner(chip: chip, reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: Theme.Space.s2)
            TimelineView(.animation(minimumInterval: 0.1, paused: session.speedrunFrozenAt != nil || session.speedrunClockStart == nil)) { timeline in
                Text(session.speedrunTimeText(at: timeline.date))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Time \(session.speedrunTimeText(at: timeline.date))")
            }
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.good)
                Text("\(session.score)")
                    .monospacedDigit()
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.bad)
                Text("\(session.speedrunMisses)")
                    .monospacedDigit()
            }
            .font(Theme.font(Theme.Size.sm, .semibold))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.score) right, \(session.speedrunMisses) wrong")
        }
        .animation(.easeOut(duration: 0.2), value: session.answerChip?.token)
    }

    private var mapCard: some View {
        Group {
            if question.kind == .click {
                ClickMapView(
                    world: session.world,
                    target: question.target,
                    state: session.isSpeedrun ? .asking : session.targetState,
                    clicked: session.isSpeedrun ? nil : session.clicked,
                    enabled: session.isSpeedrun ? session.speedrunAcceptsInput : session.phase == .asking,
                    mapScope: session.mapScope,
                    speedrunCue: session.speedrunCue?.showsMap == true ? session.speedrunCue?.mapCue : nil,
                    found: session.foundCountries
                ) { name in
                    session.click(name)
                }
                // Card shaped like the region (or world), so the land fills it (like Seterra).
                .aspectRatio(clickAspect(for: question), contentMode: .fit)
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
                    Text(mapLabel)
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

            ZStack(alignment: .top) {
                VStack(spacing: Theme.Space.s3) {
                    switch question.kind {
                    case .choice: choiceGrid
                    case .typing: typingArea
                    case .click: clickArea
                    }
                }
                if session.isSpeedrun, let cue = session.speedrunCue, !cue.showsMap {
                    SpeedrunChoiceFlash(cue: cue, reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                }
            }

            if !session.isSpeedrun {
                feedbackRow
            }
        }
    }

    private var promptText: String { question.prompt }

    private func clickAspect(for question: Question) -> Double {
        if case .some(.world) = session.mapScope {
            return 2.0
        }
        return MapViews.clickAspect(for: question.target, world: session.world)
    }

    private var mapLabel: String {
        if question.kind == .click {
            return MapViews.scopeTitle(session.mapScope, target: question.target)
        }
        return MapViews.title(for: question.target)
    }

    // MARK: Click the country

    private var clickArea: some View {
        HStack(spacing: Theme.Space.s4) {
            if let label = clickPromptLabel {
                Text(label)
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .kerning(-0.4)
                    .foregroundStyle(clickNameColor)
                    .modifier(ShakeEffect(shakes: CGFloat(session.shakeCount)))
                    .animation(reduceMotion ? nil : .linear(duration: 0.4), value: session.shakeCount)
            }
            if session.phase == .asking, !session.isSpeedrun {
                Button("I don't know") { session.giveUp() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    /// Name or capital next to the map. Flags rely on the emoji above, so no label.
    private var clickPromptLabel: String? {
        switch question.subject {
        case .countries: return question.target.name
        case .capitals: return question.answer
        case .flags: return nil
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
                            .disabled(!session.canAnswer)
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
        if option == question.answer { return .right }
        if option == session.chosen { return .wrong }
        return .dim
    }

    // MARK: Typing

    private var typingArea: some View {
        VStack(spacing: Theme.Space.s2) {
            HStack(spacing: Theme.Space.s2) {
                TextField("", text: $session.typed, prompt: Text(question.subject == .capitals ? "Type the capital" : "Type the country name").foregroundColor(Theme.text3))
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
                    .disabled(!session.canAnswer)
                    .overlay(alignment: .trailing) {
                        if session.phase == .answered, !session.isSpeedrun {
                            Image(systemName: session.lastWasRight ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(session.lastWasRight ? Theme.good : Theme.bad)
                                .padding(.trailing, Theme.Space.s3)
                                .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(!reduceMotion && session.phase == .answered && session.lastWasRight && !session.isSpeedrun ? 1.03 : 1)

                if session.canAnswer {
                    Button("Check") { session.submitTyped() }
                        .buttonStyle(AppButtonStyle(kind: .primary, height: 56))
                }
            }
            if session.phase == .asking, !session.isSpeedrun {
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

/// Segmented progress: one bar per question when the quiz is short.
/// Long quizzes (practice All) use a single bar so the window width stays sane.
private struct ProgressSteps: View {
    let total: Int
    let results: [Bool]
    let current: Int

    private static let dotLimit = 24

    var body: some View {
        Group {
            if total <= Self.dotLimit {
                HStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(color(i))
                            .frame(minWidth: 6, maxWidth: 28)
                            .frame(height: 6)
                    }
                }
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill2)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
                .frame(maxWidth: 280)
            }
        }
        .animation(Theme.Motion.slow, value: results)
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(results.count, total)) / CGFloat(total)
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
                if look == .right {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good)
                } else if look == .wrong {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.bad)
                }
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
        .scaleEffect(look == .right && !reduceMotion ? 1.04 : 1)
        .modifier(ShakeEffect(shakes: reduceMotion ? 0 : (look == .wrong ? 1 : 0)))
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: look)
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
            Text(session.locksScreen ? "Skip today's quiz?" : "End this practice?")
                .font(Theme.font(Theme.Size.md, .semibold))
                .padding(.top, Theme.Space.s3)
            Text(session.locksScreen
                 ? "Are you sure? Your streak will not count today."
                 : "You can start another practice any time.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Space.s1)
                .padding(.bottom, Theme.Space.s5)
            HStack(spacing: Theme.Space.s2) {
                Button("Keep going") { session.confirmingSkip = false }
                    .buttonStyle(AppButtonStyle(kind: .ghost, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                Button(session.locksScreen ? "Skip" : "End") { session.skip() }
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
            if session.isSpeedrun {
                speedrunFinish
            } else {
                ScoreRing(fraction: session.scoreFraction, text: "\(session.score)/\(session.askedCount)")
                    .frame(width: 200, height: 200)
                    .padding(.bottom, Theme.Space.s5)
                Text(session.finishedTitle)
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
            }

            Button(session.doneButtonTitle) { session.done() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.s8)
        .frame(maxWidth: session.isSpeedrun ? 420 : 380)
        .glass(radius: Theme.Radius.xl, strong: true)
        .padding(Theme.Space.s6)
    }

    private var speedrunFinish: some View {
        VStack(spacing: Theme.Space.s3) {
            Text(session.speedrunFinalTime)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.speedrunIsNewBest ? Theme.accent : Theme.text)
            if session.speedrunIsNewBest {
                Text("New best")
                    .font(Theme.font(Theme.Size.sm, .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Space.s3)
                    .padding(.vertical, Theme.Space.s1)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
            Text(SpeedrunKey.title(SpeedrunKey.make(subject: session.subject, style: session.speedrunStyle,
                                                    scope: session.mapScope.map { StatsScopeKey.from(practiceScope: $0) } ?? .unknown)))
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s3) {
                Label("\(session.score) right", systemImage: "checkmark")
                    .foregroundStyle(Theme.good)
                Label("\(session.speedrunMisses) wrong", systemImage: "xmark")
                    .foregroundStyle(Theme.bad)
            }
            .font(Theme.font(Theme.Size.sm, .semibold))
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "timer").foregroundStyle(Theme.text2)
                Text("Personal best")
                    .foregroundStyle(Theme.text2)
                Text(session.speedrunBestText)
                    .font(Theme.font(Theme.Size.body, .semibold))
                    .monospacedDigit()
            }
            .padding(.bottom, Theme.Space.s4)
        }
    }

    private var message: String {
        let total = session.askedCount
        if total == 0 { return "Turn on a region in the menu bar." }
        if session.unlockedByTimeLimit {
            return "Time limit reached. You got \(session.score) of \(total) right and can unlock now."
        }
        if session.score == total { return "You got all \(total) right. Nice work!" }
        return "You got \(session.score) of \(total) right. Missed ones will come back soon."
    }
}

/// Non-interactive flash for multiple choice and typing. The next question stays tappable.
private struct SpeedrunChoiceFlash: View {
    let cue: SpeedrunCue
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: Theme.Space.s2) {
            HStack(spacing: 6) {
                Image(systemName: cue.right ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(cue.chosenText)
            }
                .font(Theme.font(Theme.Size.body, .semibold))
                .foregroundStyle(cue.right ? Theme.good : Theme.bad)
                .padding(.horizontal, Theme.Space.s3)
                .padding(.vertical, Theme.Space.s2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill((cue.right ? Theme.good : Theme.bad).opacity(reduceMotion ? 0.22 : 0.18))
                )
            if !cue.right {
                Text(cue.correctText)
                    .font(Theme.font(Theme.Size.body, .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Theme.Space.s3)
                    .padding(.vertical, Theme.Space.s2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .strokeBorder(Theme.good, lineWidth: 2)
                    )
            }
        }
        .padding(.top, Theme.Space.s1)
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
