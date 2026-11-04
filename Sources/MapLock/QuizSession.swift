import SwiftUI

/// State for one 5 question quiz. Questions are picked one at a time from the deck,
/// so a missed country can come back later in the same quiz.
@MainActor
final class QuizSession: ObservableObject {
    enum Phase {
        case asking
        case answered
        case finished
    }

    let world: [Country]
    let total: Int
    private let pool: [String]
    private let byName: [String: Country]
    private let stats: StatsStore
    private let deck: DeckStore
    private let mode: QuizMode
    private let allNames: [String]
    private let onClose: () -> Void
    private var closed = false

    @Published private(set) var questions: [Question] = []
    @Published private(set) var index = 0
    @Published private(set) var phase: Phase = .asking
    @Published var typed = ""
    @Published private(set) var chosen: String? = nil
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

    init(world: [Country], pool: [String], mode: QuizMode, stats: StatsStore, deck: DeckStore,
         count: Int = QuizEngine.questionsPerSession, onClose: @escaping () -> Void) {
        self.world = world
        self.pool = pool
        self.mode = mode
        self.stats = stats
        self.deck = deck
        self.total = count
        self.onClose = onClose
        self.byName = Dictionary(world.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.allNames = world.filter { $0.quizzable }.map { $0.name }
        self.streak = stats.currentStreak()

        deck.sync(pool: pool)
        if !addNextQuestion() { phase = .finished }
        updateRound()
    }

    /// Pulls the next country from the deck. Returns false if there is nothing to ask.
    private func addNextQuestion() -> Bool {
        guard let name = deck.next(pool: pool), let target = byName[name] else { return false }
        let q = QuizEngine.makeQuestion(target: target, number: questions.count, world: world, mode: mode, stats: stats)
        questions.append(q)
        return true
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

    var isLastQuestion: Bool { index + 1 >= total }

    /// How many questions were asked in this quiz.
    var askedCount: Int { questions.isEmpty ? 0 : index + 1 }

    var isPerfect: Bool { askedCount > 0 && score == askedCount }

    // MARK: Answering

    func choose(_ option: String) {
        guard phase == .asking, let q = current else { return }
        chosen = option
        finishAnswer(right: option == q.target.name, closeEnough: false)
    }

    /// Return key in the text field: check the answer, or go on if already checked.
    func submitTyped() {
        if phase == .answered { next(); return }
        guard phase == .asking, let q = current else { return }
        if AnswerChecker.normalize(typed).isEmpty { return }
        let result = AnswerChecker.check(typed, target: q.target.name, allNames: allNames)
        finishAnswer(right: result != .wrong, closeEnough: result == .closeEnough)
    }

    func giveUp() {
        guard phase == .asking else { return }
        finishAnswer(right: false, closeEnough: false)
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
            feedback = closeEnough ? "Close enough! It is spelled \(name)." : "Correct! \(name)"
        } else {
            feedback = "It was \(name). It will come back soon."
        }
        phase = .answered
        updateRound()
    }

    func next() {
        guard phase == .answered else { return }
        if index + 1 < total && addNextQuestion() {
            index += 1
            typed = ""
            chosen = nil
            feedback = ""
            phase = .asking
        } else {
            streak = stats.finishSession()
            phase = .finished
        }
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
