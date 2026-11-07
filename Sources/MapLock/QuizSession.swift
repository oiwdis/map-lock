import SwiftUI

/// State for one quiz. Questions are picked one at a time from the deck,
/// so a missed country can come back later in the same quiz.
@MainActor
final class QuizSession: ObservableObject {
    enum Phase {
        case asking
        case answered
        case finished
    }

    enum Kind {
        /// Full-screen lock overlay (unlock / schedule).
        case lock
        /// Practice from the home window or menu: no screen lock.
        case practice
    }

    let world: [Country]
    let kind: Kind
    let subject: QuizSubject
    let mapScope: PracticeScope?
    private let pool: [String]
    private let byName: [String: Country]
    private let stats: StatsStore
    private let deck: DeckStore
    private let mode: QuizMode
    private let quizType: QuizType
    private let allNames: [String]
    var onClose: () -> Void
    private var closed = false
    private let requirePerfect: Bool
    private let unlockDeadline: Date?
    private let startedAt: Date
    private var plannedCount: Int
    /// Countries missed in this quiz that have not been answered right since.
    private var pendingRetry: [String] = []

    @Published private(set) var total: Int
    @Published private(set) var questions: [Question] = []
    @Published private(set) var index = 0
    @Published private(set) var phase: Phase = .asking
    @Published var typed = ""
    @Published private(set) var chosen: String? = nil
    /// The country clicked on a "Click the country" question.
    @Published private(set) var clicked: String? = nil
    @Published private(set) var lastWasRight = false
    @Published private(set) var feedback = ""
    @Published private(set) var score = 0
    @Published private(set) var streak = 0
    @Published private(set) var roundShown = 0
    @Published private(set) var roundTotal = 0
    @Published var confirmingSkip = false
    /// One entry per answered question: true = right.
    @Published private(set) var results: [Bool] = []
    /// Bumped on each right / wrong answer to play the pulse / shake.
    @Published private(set) var pulseCount = 0
    @Published private(set) var shakeCount = 0
    /// True when the time limit ended a require-perfect lock quiz.
    @Published private(set) var unlockedByTimeLimit = false

    let isSpeedrun: Bool
    let speedrunStyle: PracticeAnswerStyle
    /// When false, a race countdown is up and answers are ignored.
    @Published var speedrunAcceptsInput = true
    var onSpeedrunProgress: ((Int, Int, Int, Bool) -> Void)?
    @Published private(set) var speedrunClockStart: Date?
    @Published private(set) var speedrunFrozenAt: Date?
    @Published var speedrunCue: SpeedrunCue?
    @Published private(set) var speedrunIsNewBest = false
    @Published private(set) var speedrunBestText = "-"
    @Published private(set) var speedrunFinalTime = "00:00.0"
    private var cueToken = 0

    /// How long a click result stays on screen before the next question.
    static let rightClickPause: Double = 0.9
    static let wrongClickPause: Double = 2.2

    init(world: [Country], pool: [String], mode: QuizMode, quizType: QuizType = .name,
         subject: QuizSubject = .countries, stats: StatsStore, deck: DeckStore,
         count: Int = QuizEngine.questionsPerSession,
         kind: Kind = .lock,
         requirePerfect: Bool = false,
         timeLimit: TimeInterval? = nil,
         mapScope: PracticeScope? = nil,
         speedrun: Bool = false,
         speedrunStyle: PracticeAnswerStyle = .clickMap,
         speedrunOrder: [String]? = nil,
         now: Date = Date(),
         onClose: @escaping () -> Void) {
        self.world = world
        self.pool = pool
        self.mode = mode
        self.quizType = quizType
        self.subject = subject
        self.stats = stats
        self.deck = deck
        self.plannedCount = max(count, 1)
        self.total = max(count, 1)
        self.kind = kind
        self.requirePerfect = requirePerfect && kind == .lock
        self.startedAt = now
        if self.requirePerfect {
            self.unlockDeadline = now.addingTimeInterval(timeLimit ?? AppSettings.perfectTimeLimit)
        } else {
            self.unlockDeadline = nil
        }
        self.mapScope = mapScope
        self.isSpeedrun = speedrun
        self.speedrunStyle = speedrunStyle
        self.onClose = onClose
        self.byName = Dictionary(world.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.allNames = world.filter { $0.quizzable }.map { $0.name }
        self.streak = stats.currentStreak()

        if speedrun {
            let names = speedrunOrder ?? SpeedrunRules.shuffled(pool)
            for name in names {
                guard let target = byName[name] else { continue }
                appendQuestion(for: target)
            }
            self.total = max(questions.count, 1)
            self.plannedCount = self.total
            if questions.isEmpty { phase = .finished }
        } else {
            deck.sync(pool: pool)
            if !addNextQuestion() { phase = .finished }
        }
        updateRound()
    }

    var speedrunMisses: Int { max(results.count - score, 0) }

    func noteSpeedrunVisible(now: Date = Date()) {
        guard isSpeedrun, speedrunClockStart == nil, phase == .asking, speedrunAcceptsInput else { return }
        speedrunClockStart = now
    }

    func speedrunTimeText(at now: Date) -> String {
        guard let speedrunClockStart else { return SpeedrunClock.format(0) }
        let end = speedrunFrozenAt ?? now
        return SpeedrunClock.format(end.timeIntervalSince(speedrunClockStart))
    }

    var locksScreen: Bool { kind == .lock }

    var canAnswer: Bool { phase == .asking && (!isSpeedrun || speedrunAcceptsInput) }

    var secondsLeft: Int? {
        guard let unlockDeadline else { return nil }
        return max(0, Int(unlockDeadline.timeIntervalSince(Date())))
    }

    var timeExpired: Bool {
        guard let unlockDeadline else { return false }
        return Date() >= unlockDeadline
    }

    /// Pulls the next country from the deck. Returns false if there is nothing to ask.
    private func addNextQuestion() -> Bool {
        guard let name = deck.next(pool: pool), let target = byName[name] else { return false }
        appendQuestion(for: target)
        return true
    }

    /// Forces a retry of a missed country (for require-perfect).
    private func addRetryQuestion() -> Bool {
        guard let name = pendingRetry.first, let target = byName[name] else { return false }
        pendingRetry.removeFirst()
        // Put it back at the end if they miss again (finishAnswer will re-append).
        appendQuestion(for: target)
        return true
    }

    private func appendQuestion(for target: Country) {
        let q = QuizEngine.makeQuestion(target: target, number: questions.count, world: world, mode: mode,
                                       type: quizType, subject: subject, stats: stats)
        questions.append(q)
    }

    private func updateRound() {
        let p = deck.progress(pool: pool)
        roundShown = p.shown
        roundTotal = p.total
    }

    var current: Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    /// 0...1 for the score ring.
    var scoreFraction: Double {
        askedCount == 0 ? 0 : Double(score) / Double(askedCount)
    }

    var progressText: String {
        "\(min(index + 1, total)) of \(total)"
    }

    var roundText: String {
        "Round progress: \(roundShown) of \(roundTotal)"
    }

    var targetState: TargetState {
        guard phase == .answered else { return .asking }
        return lastWasRight ? .right : .wrong
    }

    var isLastQuestion: Bool {
        if shouldContinueForPerfect() { return false }
        return index + 1 >= total
    }

    /// How many questions were asked in this quiz.
    var askedCount: Int { results.count }

    var isPerfect: Bool { askedCount > 0 && score == askedCount && pendingRetry.isEmpty }

    var finishedTitle: String {
        if kind == .practice { return askedCount == 0 ? "Nothing to ask" : "Practice done" }
        return askedCount == 0 ? "Nothing to ask" : "Unlocked!"
    }

    var doneButtonTitle: String {
        kind == .practice ? "Close" : "Back to desktop"
    }

    // MARK: Answering

    func choose(_ option: String) {
        guard phase == .asking, let q = current else { return }
        if isSpeedrun {
            guard speedrunAcceptsInput else { return }
            speedrunResolve(right: option == q.answer, chosen: option, clicked: nil, question: q)
            return
        }
        chosen = option
        finishAnswer(right: option == q.answer, closeEnough: false)
    }

    /// Return key in the text field: check the answer, or go on if already checked.
    func submitTyped() {
        if !isSpeedrun, phase == .answered { next(); return }
        guard phase == .asking, let q = current else { return }
        if isSpeedrun, !speedrunAcceptsInput { return }
        if AnswerChecker.normalize(typed).isEmpty { return }
        let result: AnswerChecker.Result
        switch q.subject {
        case .countries, .flags:
            result = AnswerChecker.check(typed, target: q.target.name, allNames: allNames)
        case .capitals:
            result = AnswerChecker.checkCapital(typed, country: q.target.name)
        }
        if isSpeedrun {
            speedrunResolve(right: result != .wrong, chosen: typed, clicked: nil, question: q)
            return
        }
        finishAnswer(right: result != .wrong, closeEnough: result == .closeEnough)
    }

    /// A click on the map for a "Click the country" question. `name` is the country hit,
    /// already worked out by ClickMap. Clicks in the sea never get here.
    func click(_ name: String) {
        guard phase == .asking, let q = current, q.kind == .click else { return }
        if isSpeedrun {
            guard speedrunAcceptsInput else { return }
            speedrunResolve(right: name == q.target.name, chosen: name, clicked: name, question: q)
            return
        }
        clicked = name
        let right = name == q.target.name
        finishAnswer(right: right, closeEnough: false)
        if !right {
            feedback = "That was \(name). \(q.target.name) is shown in yellow."
        }
        let at = index
        let pause = right ? Self.rightClickPause : Self.wrongClickPause
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            guard let self, self.index == at, self.phase == .answered, !self.confirmingSkip, !self.closed else { return }
            self.next()
        }
    }

    func giveUp() {
        guard phase == .asking else { return }
        finishAnswer(right: false, closeEnough: false)
        if let q = current, q.kind == .click {
            feedback = "\(q.target.name) is shown in yellow. It will come back soon."
        }
    }

    private func finishAnswer(right: Bool, closeEnough: Bool) {
        guard let q = current else { return }
        let name = q.target.name
        lastWasRight = right
        if right { score += 1 }
        results.append(right)
        if right { pulseCount += 1 } else { shakeCount += 1 }
        stats.record(name, correct: right)
        deck.answered(name, correct: right)

        if right {
            pendingRetry.removeAll { $0 == name }
            switch q.subject {
            case .countries, .flags:
                feedback = closeEnough ? "Close enough! It is spelled \(name)." : "Correct! \(name)"
            case .capitals:
                let capital = q.answer
                feedback = closeEnough ? "Close enough! The capital is \(capital)." : "Correct! \(capital)"
            }
        } else {
            if !pendingRetry.contains(name) { pendingRetry.append(name) }
            switch q.subject {
            case .countries, .flags:
                feedback = "It was \(name). It will come back soon."
            case .capitals:
                feedback = "It was \(q.answer). It will come back soon."
            }
        }
        phase = .answered
        updateRound()
    }

    func next() {
        guard phase == .answered else { return }
        let baseDone = index + 1 >= plannedCount
        if !baseDone {
            if addNextQuestion() {
                advance()
            } else {
                finishSession()
            }
            return
        }

        // Planned questions are done. Keep going for require-perfect if needed.
        if shouldContinueForPerfect() {
            total = index + 2
            if addRetryQuestion() || addNextQuestion() {
                advance()
                return
            }
        }
        finishSession()
    }

    /// Pure decision used by tests too (via QuizRules).
    func shouldContinueForPerfect(now: Date = Date()) -> Bool {
        QuizRules.shouldContinue(
            requirePerfect: requirePerfect,
            pendingRetryCount: pendingRetry.count,
            deadline: unlockDeadline,
            now: now
        )
    }

    private func advance() {
        index += 1
        typed = ""
        chosen = nil
        clicked = nil
        feedback = ""
        phase = .asking
        updateRound()
    }

    private func speedrunResolve(right: Bool, chosen: String, clicked: String?, question: Question) {
        noteSpeedrunVisible()
        lastWasRight = right
        if right { score += 1 }
        results.append(right)
        if right { pulseCount += 1 } else { shakeCount += 1 }
        stats.record(question.target.name, correct: right)
        cueToken += 1
        let token = cueToken
        speedrunCue = SpeedrunCue(
            token: token,
            right: right,
            chosenText: chosen,
            correctText: question.answer,
            correctCountry: question.target.name,
            wrongCountry: (right || clicked == nil || clicked == question.target.name) ? nil : clicked,
            showsMap: question.kind == .click
        )
        let delay = right ? 0.4 : 0.6
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.cueToken == token else { return }
            self.speedrunCue = nil
        }
        let answered = results.count
        let done = answered >= questions.count
        onSpeedrunProgress?(answered, max(questions.count, 1), speedrunMisses, done)
        if done {
            finishSession()
        } else {
            index += 1
            typed = ""
            self.chosen = nil
            self.clicked = nil
            feedback = ""
            phase = .asking
        }
    }

    private func finishSession() {
        if isSpeedrun {
            let now = Date()
            if speedrunClockStart == nil { speedrunClockStart = now }
            speedrunFrozenAt = now
            let duration = now.timeIntervalSince(speedrunClockStart ?? now)
            speedrunFinalTime = SpeedrunClock.format(duration)
            let scopeKey = mapScope.map { StatsScopeKey.from(practiceScope: $0) } ?? .unknown
            let key = SpeedrunKey.make(subject: subject, style: speedrunStyle, scope: scopeKey)
            let saved = stats.recordSpeedrun(key: key, duration: duration, misses: speedrunMisses,
                                             countries: score, now: now)
            speedrunIsNewBest = saved.isNewBest
            speedrunBestText = saved.best > 0 ? SpeedrunClock.format(saved.best) : "-"
            streak = stats.finishSession(now: now)
            phase = .finished
            return
        }
        if requirePerfect, !pendingRetry.isEmpty, timeExpired {
            unlockedByTimeLimit = true
        }
        let duration = Date().timeIntervalSince(startedAt)
        streak = stats.finishSession()
        let scopeKey: StatsScopeKey
        if let mapScope {
            scopeKey = StatsScopeKey.from(practiceScope: mapScope)
        } else {
            let regions = Set(pool.compactMap { byName[$0]?.region })
            scopeKey = StatsScopeKey.from(poolRegions: regions)
        }
        stats.recordQuiz(score: score, total: askedCount, duration: duration,
                         missed: Array(Set(pendingRetry)),
                         kind: kind == .practice ? .practice : .lock,
                         subject: subject, scope: scopeKey)
        phase = .finished
        updateRound()
    }

    // MARK: Closing

    /// Close button on the finished screen.
    func done() { close() }

    /// Emergency skip, after "Are you sure?".
    func skip() {
        confirmingSkip = false
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        // Let the button action finish before the window goes away.
        Task { @MainActor [weak self] in
            self?.onClose()
        }
    }
}
