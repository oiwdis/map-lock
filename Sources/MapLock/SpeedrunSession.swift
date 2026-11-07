import SwiftUI

/// One speedrun: every country in a place, shuffled, click to find it, clock running.
@MainActor
final class SpeedrunSession: ObservableObject {
    enum Phase {
        case asking
        case finished
    }

    let world: [Country]
    let scope: PracticeScope
    private let byName: [String: Country]
    private let stats: StatsStore
    private let onClose: () -> Void
    private var progress: SpeedrunProgress
    private var closed = false
    private var recorded = false
    private var flashTask: Task<Void, Never>?
    private var flashToken = 0

    /// How long a wrong country stays red. Clicks keep working during the flash.
    static let flashSeconds: Double = 0.35

    @Published private(set) var phase: Phase = .asking
    @Published private(set) var index = 0
    @Published private(set) var misses = 0
    /// Country that was just clicked wrong. Nil once the flash is over.
    @Published private(set) var flashCountry: String?
    @Published private(set) var shakeCount = 0
    @Published private(set) var clockStart: Date?
    @Published private(set) var frozenAt: Date?
    @Published private(set) var isNewBest = false
    @Published private(set) var personalBest: TimeInterval = 0
    @Published var confirmingEnd = false

    init(world: [Country], scope: PracticeScope, stats: StatsStore,
         order: [String]? = nil, onClose: @escaping () -> Void) {
        self.world = world
        self.scope = scope
        self.stats = stats
        self.onClose = onClose
        self.byName = Dictionary(world.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let names = order ?? SpeedrunRules.shuffled(SpeedrunPool.names(world: world, scope: scope))
        self.progress = SpeedrunProgress(order: names)
        if names.isEmpty { phase = .finished }
    }

    var scopeTitle: String { scope.title }
    var total: Int { progress.order.count }
    var currentName: String? { progress.current }
    var currentCountry: Country? { currentName.flatMap { byName[$0] } }
    var clockRunning: Bool { clockStart != nil && phase == .asking }

    var progressText: String {
        guard total > 0 else { return "0 of 0" }
        if phase == .finished { return "\(total) of \(total)" }
        return "\(min(index + 1, total)) of \(total)"
    }

    var missesText: String { misses == 1 ? "1 miss" : "\(misses) misses" }

    var accuracyText: String {
        let pct = SpeedrunRules.accuracy(countries: total, misses: misses)
        return String(format: "%.0f%%", pct * 100)
    }

    var personalBestText: String {
        personalBest > 0 ? SpeedrunClock.format(personalBest) : "-"
    }

    /// Starts the clock the first time the first country is on screen.
    func startClockIfNeeded(now: Date = Date()) {
        guard clockStart == nil, phase == .asking, total > 0 else { return }
        clockStart = now
    }

    func timeText(at now: Date) -> String {
        guard let clockStart else { return SpeedrunClock.format(0) }
        let end = frozenAt ?? now
        return SpeedrunClock.format(end.timeIntervalSince(clockStart))
    }

    var finalTimeText: String { timeText(at: frozenAt ?? Date()) }

    func click(_ name: String) {
        guard phase == .asking else { return }
        startClockIfNeeded()
        switch progress.click(name) {
        case .ignored:
            return
        case .miss:
            misses = progress.misses
            shakeCount += 1
            flash(name)
        case .advanced:
            clearFlash()
            index = progress.index
        case .finished:
            clearFlash()
            index = progress.index
            finish()
        }
    }

    func done() { close() }

    func endWithoutSaving() {
        confirmingEnd = false
        close()
    }

    private func flash(_ name: String) {
        flashToken += 1
        let token = flashToken
        flashCountry = name
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.flashToken == token, self.phase == .asking else { return }
            self.flashCountry = nil
        }
    }

    private func clearFlash() {
        flashTask?.cancel()
        flashToken += 1
        flashCountry = nil
    }

    private func finish() {
        guard !recorded else { return }
        recorded = true
        let now = Date()
        if clockStart == nil { clockStart = now }
        frozenAt = now
        let duration = now.timeIntervalSince(clockStart ?? now)
        let saved = stats.recordSpeedrun(
            scope: StatsScopeKey.from(practiceScope: scope),
            duration: duration,
            misses: misses,
            countries: total,
            now: now
        )
        isNewBest = saved.isNewBest
        personalBest = saved.best
        phase = .finished
    }

    private func close() {
        guard !closed else { return }
        closed = true
        flashTask?.cancel()
        Task { @MainActor [weak self] in
            self?.onClose()
        }
    }
}
