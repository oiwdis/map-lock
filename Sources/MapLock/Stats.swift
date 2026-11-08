import Foundation

/// How well a single country is known (practice and unlock combined).
struct CountryStat: Codable, Equatable {
    var seen: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    /// Leitner style box: 0 = just missed, 5 = known very well.
    var box: Int = 0
    var lastSeen: Date? = nil
}

enum QuizRecordKind: String, Codable, CaseIterable {
    case lock
    case practice

    var title: String {
        switch self {
        case .lock: return "Unlock"
        case .practice: return "Practice"
        }
    }
}

/// Where a quiz was scoped. Stored as a stable string for Codable history.
enum StatsScopeKey: String, Codable, CaseIterable {
    case world
    case africa = "Africa"
    case asia = "Asia"
    case europe = "Europe"
    case northAmerica = "North America"
    case southAmerica = "South America"
    case several
    case unknown
    /// A quiz whose place cannot be recovered.
    case other

    var title: String {
        switch self {
        case .world: return "Whole world"
        case .several: return "Several regions"
        case .unknown, .other: return "Other"
        default: return rawValue
        }
    }

    static func from(practiceScope: PracticeScope?) -> StatsScopeKey {
        guard let practiceScope else { return .other }
        switch practiceScope {
        case .world: return .world
        case .region(let r):
            return StatsScopeKey(rawValue: r.rawValue) ?? .other
        }
    }

    static func from(poolRegions: Set<Region>) -> StatsScopeKey {
        if poolRegions.isEmpty { return .other }
        if poolRegions.count == 1, let only = poolRegions.first {
            return StatsScopeKey(rawValue: only.rawValue) ?? .other
        }
        return .several
    }

    /// A saved quiz with no place. Missed country names win. A total that matches
    /// one continent, or the whole world, is used when the miss list is empty.
    static func infer(missed: [String], total: Int, regionOf: (String) -> StatsScopeKey?,
                      counts: [StatsScopeKey: Int], worldCount: Int) -> StatsScopeKey {
        let places = Set(missed.compactMap { name -> StatsScopeKey? in
            guard let key = regionOf(name), key != .unknown, key != .other, key != .several, key != .world else { return nil }
            return key
        })
        if places.count == 1, let only = places.first { return only }
        if places.count >= 2 {
            if worldCount > 0, abs(total - worldCount) <= 2 { return .world }
            return .several
        }
        if total > 0 {
            if worldCount > 0, abs(total - worldCount) <= 2 { return .world }
            let near = counts.filter { key, count in
                key != .world && key != .unknown && key != .other && key != .several && abs(count - total) <= 1
            }
            if near.count == 1, let key = near.keys.first { return key }
            let africa = counts[.africa] ?? 0
            let asia = counts[.asia] ?? 0
            if africa > 0, asia > 0, abs(total - (africa + asia)) <= 2 { return .several }
        }
        return .other
    }

    var needsPlaceRepair: Bool {
        self == .unknown || self == .other
    }

    /// Places a speedrun can be scored against, in the same order as the practice picker.
    static let speedrunOrder: [StatsScopeKey] = [
        .africa, .asia, .europe, .northAmerica, .southAmerica, .world,
    ]
}

/// One finished speedrun, kept apart from practice and unlock quizzes.
struct SpeedrunRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var duration: TimeInterval
    var misses: Int
    var countries: Int
    var scopeRaw: String

    var scope: StatsScopeKey {
        StatsScopeKey(rawValue: scopeRaw) ?? .unknown
    }
}

/// One finished quiz, for the Stats page.
struct QuizRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var score: Int
    var total: Int
    var duration: TimeInterval
    var missed: [String]
    var kind: QuizRecordKind
    /// QuizSubject.rawValue. Empty on very old records.
    var subjectRaw: String = QuizSubject.countries.rawValue
    var scopeRaw: String = StatsScopeKey.unknown.rawValue

    var percent: Double { total == 0 ? 0 : Double(score) / Double(total) }
    var wrong: Int { max(total - score, 0) }

    var subject: QuizSubject {
        QuizSubject(rawValue: subjectRaw) ?? .countries
    }

    var scope: StatsScopeKey {
        StatsScopeKey(rawValue: scopeRaw) ?? .unknown
    }

    enum CodingKeys: String, CodingKey {
        case id, date, score, total, duration, missed, kind, subjectRaw, scopeRaw
    }

    init(date: Date, score: Int, total: Int, duration: TimeInterval, missed: [String],
         kind: QuizRecordKind, subject: QuizSubject, scope: StatsScopeKey,
         id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.score = score
        self.total = total
        self.duration = duration
        self.missed = missed
        self.kind = kind
        self.subjectRaw = subject.rawValue
        self.scopeRaw = scope.rawValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        score = try c.decode(Int.self, forKey: .score)
        total = try c.decode(Int.self, forKey: .total)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        missed = try c.decodeIfPresent([String].self, forKey: .missed) ?? []
        kind = try c.decode(QuizRecordKind.self, forKey: .kind)
        subjectRaw = try c.decodeIfPresent(String.self, forKey: .subjectRaw)
            ?? QuizSubject.countries.rawValue
        scopeRaw = try c.decodeIfPresent(String.self, forKey: .scopeRaw)
            ?? StatsScopeKey.unknown.rawValue
    }
}

/// One row in a breakdown list (place or mode).
struct StatsBreakdownRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let quizzes: Int
    let correct: Int
    let total: Int

    var percent: Double { total == 0 ? 0 : Double(correct) / Double(total) }
    var percentText: String {
        guard total > 0 else { return "-" }
        return String(format: "%.0f%%", percent * 100)
    }
    var detailText: String {
        guard quizzes > 0 else { return "No quizzes yet" }
        let q = quizzes == 1 ? "1 quiz" : "\(quizzes) quizzes"
        return "\(q) · \(correct) of \(total)"
    }
}

/// One most-missed country row.
struct StatsMissRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let wrong: Int
}

/// One recent session line.
struct StatsHistoryRow: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kindTitle: String
    let subjectTitle: String
    let scopeTitle: String
    let scoreText: String
    let isPractice: Bool
}

/// Totals for Practice or Unlock.
struct StatsKindSummary: Equatable {
    var quizzes: Int = 0
    var correct: Int = 0
    var total: Int = 0
    var byScope: [StatsBreakdownRow] = []
    var bySubject: [StatsBreakdownRow] = []
    var mostMissed: [StatsMissRow] = []

    var percent: Double { total == 0 ? 0 : Double(correct) / Double(total) }
    var percentText: String {
        guard total > 0 else { return "-" }
        return String(format: "%.0f%%", percent * 100)
    }
    var hasData: Bool { quizzes > 0 || total > 0 }
}

/// Snapshot the Stats tab reads. Built from StatsStore so the UI stays simple.
struct StatsSnapshot: Equatable {
    var overallAccuracyText: String = "-"
    var totalQuestionsText: String = "0"
    var currentStreakText: String = "0 days"
    var bestStreakText: String = "0 days"
    var bestPercentText: String = "-"
    var bestTimeText: String = "-"
    var roundText: String = "0 of 0"
    var practice = StatsKindSummary()
    var unlock = StatsKindSummary()
    var history: [StatsHistoryRow] = []
    var dayHistory: [StatsBreakdownRow] = []
    var mostMissed: [StatsMissRow] = []
    var speedrunBests: [SpeedrunBestRow] = []
    var speedrunRuns: [SpeedrunHistoryRow] = []
    var hasAnyQuiz: Bool = false
}

/// Fastest speedrun for one place. `timeText` is "-" until a run is saved.
struct SpeedrunBestRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let scopeTitle: String
    let timeText: String
}

/// One finished speedrun, newest first in the Stats tab.
struct SpeedrunHistoryRow: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let scopeTitle: String
    let timeText: String
    let misses: Int
    let accuracyText: String
}

/// What saving a speedrun did to that place's best time.
struct SpeedrunSaveResult: Equatable {
    var isNewBest: Bool
    var best: TimeInterval
}

/// Saves per-country results, the daily streak, and recent quiz scores in UserDefaults.
final class StatsStore {
    private let defaults: UserDefaults
    private(set) var stats: [String: CountryStat] = [:]
    private(set) var quizzes: [QuizRecord] = []
    private(set) var speedruns: [SpeedrunRecord] = []
    private var speedrunBests: [String: Double] = [:]
    /// Country places, filled once the map has loaded. Used again after a sync.
    private var scopeCensus: (regionOf: [String: StatsScopeKey], counts: [StatsScopeKey: Int], worldCount: Int)?

    private enum Keys {
        static let stats = "maplock.stats"
        static let streak = "maplock.streak"
        static let bestStreak = "maplock.bestStreak"
        static let lastDay = "maplock.lastQuizDay"
        static let quizzes = "maplock.quizRecords"
        static let bestPercent = "maplock.bestPercent"
        static let bestTime = "maplock.bestTimeSeconds"
        static let speedruns = "maplock.speedrunRecords"
        static let speedrunBests = "maplock.speedrunBests"
    }

    private static let maxQuizRecords = 100
    private static let maxSpeedrunRecords = 100

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.stats),
           let decoded = try? JSONDecoder().decode([String: CountryStat].self, from: data) {
            stats = decoded
        }
        if let data = defaults.data(forKey: Keys.quizzes),
           let decoded = try? JSONDecoder().decode([QuizRecord].self, from: data) {
            quizzes = decoded
        }
        if let data = defaults.data(forKey: Keys.speedruns),
           let decoded = try? JSONDecoder().decode([SpeedrunRecord].self, from: data) {
            speedruns = decoded
        }
        if let data = defaults.data(forKey: Keys.speedrunBests),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            speedrunBests = Self.migratedBests(decoded)
        }
        speedruns = speedruns.map { run in
            var copy = run
            copy.scopeRaw = SpeedrunKey.canonical(run.scopeRaw)
            return copy
        }
    }

    private static func migratedBests(_ raw: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in raw where value > 0 {
            let canonical = SpeedrunKey.canonical(key)
            if let current = out[canonical] {
                out[canonical] = min(current, value)
            } else {
                out[canonical] = value
            }
        }
        return out
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: Keys.stats)
        }
    }

    private func saveQuizzes() {
        if let data = try? JSONEncoder().encode(quizzes) {
            defaults.set(data, forKey: Keys.quizzes)
        }
    }

    private func saveSpeedruns() {
        if let data = try? JSONEncoder().encode(speedruns) {
            defaults.set(data, forKey: Keys.speedruns)
        }
        if let data = try? JSONEncoder().encode(speedrunBests) {
            defaults.set(data, forKey: Keys.speedrunBests)
        }
    }

    func stat(for name: String) -> CountryStat? { stats[name] }

    /// Record one answer.
    func record(_ name: String, correct: Bool, now: Date = Date()) {
        var s = stats[name] ?? CountryStat()
        s.seen += 1
        s.lastSeen = now
        if correct {
            s.correct += 1
            s.box = min(s.box + 1, 5)
        } else {
            s.wrong += 1
            s.box = 0
        }
        stats[name] = s
        let snapshot = stats
        let store = defaults
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                store.set(data, forKey: Keys.stats)
            }
        }
    }

    /// Countries answered right at least 3 times in a row.
    func learnedCount(among names: [String]) -> Int {
        names.filter { (stats[$0]?.box ?? 0) >= 3 }.count
    }

    /// Most-missed countries (highest wrong count, then lowest accuracy).
    func mostMissed(limit: Int = 10) -> [(name: String, wrong: Int, seen: Int)] {
        stats
            .filter { $0.value.wrong > 0 }
            .map { (name: $0.key, wrong: $0.value.wrong, seen: $0.value.seen) }
            .sorted {
                if $0.wrong != $1.wrong { return $0.wrong > $1.wrong }
                let a0 = $0.seen == 0 ? 0.0 : Double($0.seen - $0.wrong) / Double($0.seen)
                let a1 = $1.seen == 0 ? 0.0 : Double($1.seen - $1.wrong) / Double($1.seen)
                return a0 < a1
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Quiz records

    /// Best score as a 0...1 fraction. 0 if none yet.
    var bestPercent: Double {
        let stored = defaults.double(forKey: Keys.bestPercent)
        if stored > 0 { return stored }
        return quizzes.map(\.percent).max() ?? 0
    }

    /// Fastest finished quiz in seconds (only perfect scores count). Nil if none.
    var bestTimeSeconds: Double? {
        if defaults.object(forKey: Keys.bestTime) != nil {
            let v = defaults.double(forKey: Keys.bestTime)
            return v > 0 ? v : nil
        }
        return quizzes.filter { $0.score == $0.total && $0.total > 0 }.map(\.duration).min()
    }

    var totalSeen: Int { stats.values.reduce(0) { $0 + $1.seen } }
    var totalCorrect: Int { stats.values.reduce(0) { $0 + $1.correct } }

    var overallAccuracy: Double {
        let seen = totalSeen
        guard seen > 0 else { return 0 }
        return Double(totalCorrect) / Double(seen)
    }

    func recordQuiz(score: Int, total: Int, duration: TimeInterval, missed: [String],
                    kind: QuizRecordKind, subject: QuizSubject, scope: StatsScopeKey,
                    now: Date = Date()) {
        guard total > 0 else { return }
        let record = QuizRecord(date: now, score: score, total: total, duration: duration,
                                missed: missed, kind: kind, subject: subject, scope: scope)
        quizzes.insert(record, at: 0)
        if quizzes.count > Self.maxQuizRecords {
            quizzes = Array(quizzes.prefix(Self.maxQuizRecords))
        }
        saveQuizzes()

        let percent = record.percent
        if percent > bestPercent {
            defaults.set(percent, forKey: Keys.bestPercent)
        }
        if score == total, duration > 0 {
            if let best = bestTimeSeconds {
                if duration < best { defaults.set(duration, forKey: Keys.bestTime) }
            } else {
                defaults.set(duration, forKey: Keys.bestTime)
            }
        }
    }

    // MARK: Daily streak

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The streak as it stands right now (0 if a day was missed).
    func currentStreak(now: Date = Date()) -> Int {
        let streak = defaults.integer(forKey: Keys.streak)
        guard let last = defaults.string(forKey: Keys.lastDay) else { return 0 }
        let today = Self.dayString(now)
        let yesterday = Self.dayString(Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        return (last == today || last == yesterday) ? streak : 0
    }

    var bestStreak: Int { defaults.integer(forKey: Keys.bestStreak) }

    /// Call when a quiz is finished (not skipped). Returns the new streak.
    @discardableResult
    func finishSession(now: Date = Date()) -> Int {
        let today = Self.dayString(now)
        let yesterday = Self.dayString(Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        let last = defaults.string(forKey: Keys.lastDay)
        var streak = defaults.integer(forKey: Keys.streak)

        if last == today {
            streak = max(streak, 1)
        } else if last == yesterday {
            streak += 1
        } else {
            streak = 1
        }
        defaults.set(streak, forKey: Keys.streak)
        defaults.set(today, forKey: Keys.lastDay)
        if streak > bestStreak { defaults.set(streak, forKey: Keys.bestStreak) }
        return streak
    }

    // MARK: Snapshot for the Stats tab

    func snapshot(roundText: String, now: Date = Date()) -> StatsSnapshot {
        var snap = StatsSnapshot()
        let seen = totalSeen
                snap.overallAccuracyText = seen > 0
            ? String(format: "%.0f%%", overallAccuracy * 100) : "-"
        snap.totalQuestionsText = "\(seen)"
        let streak = currentStreak(now: now)
        snap.currentStreakText = streak == 1 ? "1 day" : "\(streak) days"
        let best = bestStreak
        snap.bestStreakText = best == 1 ? "1 day" : "\(best) days"
        let pct = bestPercent
        snap.bestPercentText = pct > 0 ? String(format: "%.0f%%", pct * 100) : "-"
        if let t = bestTimeSeconds {
            let sec = Int(t.rounded())
            snap.bestTimeText = "\(sec / 60):" + String(format: "%02d", sec % 60)
        } else {
            snap.bestTimeText = "-"
        }
        snap.roundText = roundText
        snap.mostMissed = mostMissed(limit: 10).map { StatsMissRow(name: $0.name, wrong: $0.wrong) }
        snap.practice = summary(for: .practice)
        snap.unlock = summary(for: .lock)
        snap.history = recentHistory(limit: 12)
        snap.dayHistory = recentDays(limit: 14, now: now)
        snap.speedrunBests = speedrunBestRows()
        snap.speedrunRuns = recentSpeedruns(limit: 12)
        snap.hasAnyQuiz = !quizzes.isEmpty || seen > 0
        return snap
    }

    /// Saves a finished speedrun and that place's fastest time. Does not change practice or unlock stats.
    @discardableResult
    func recordSpeedrun(key rawKey: String, duration: TimeInterval, misses: Int, countries: Int,
                        now: Date = Date()) -> SpeedrunSaveResult {
        let key = SpeedrunKey.canonical(rawKey)
        let previous = speedrunBests[key]
        let isNew = SpeedrunRules.isNewBest(duration: duration, previous: previous)
        if isNew { speedrunBests[key] = duration }
        if duration.isFinite, duration >= 0, countries + max(misses, 0) > 0 {
            let record = SpeedrunRecord(date: now, duration: duration, misses: max(misses, 0),
                                        countries: countries, scopeRaw: key)
            speedruns.insert(record, at: 0)
            if speedruns.count > Self.maxSpeedrunRecords {
                speedruns = Array(speedruns.prefix(Self.maxSpeedrunRecords))
            }
        }
        saveSpeedruns()
        let best = speedrunBests[key] ?? 0
        return SpeedrunSaveResult(isNewBest: isNew, best: best)
    }

    private func speedrunBestRows() -> [SpeedrunBestRow] {
        speedrunBests.keys.sorted().compactMap { key in
            guard let time = speedrunBests[key], time > 0 else { return nil }
            return SpeedrunBestRow(key: key, scopeTitle: SpeedrunKey.title(key), timeText: SpeedrunClock.format(time))
        }
    }

    /// Subject, answer method, and place of the newest finished speedrun.
    func latestSpeedrunPick() -> (subject: QuizSubject, style: PracticeAnswerStyle, region: PracticeChoice)? {
        guard let raw = speedruns.first?.scopeRaw else { return nil }
        let parts = SpeedrunKey.canonical(raw).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let subject = QuizSubject(rawValue: parts[0]),
              let style = PracticeAnswerStyle(rawValue: parts[1]) else { return nil }
        switch StatsScopeKey(rawValue: parts[2]) ?? .unknown {
        case .africa: return (subject, style, .africa)
        case .asia: return (subject, style, .asia)
        case .europe: return (subject, style, .europe)
        case .northAmerica: return (subject, style, .northAmerica)
        case .southAmerica: return (subject, style, .southAmerica)
        case .world: return (subject, style, .world)
        case .several, .unknown, .other: return nil
        }
    }

    private func recentSpeedruns(limit: Int) -> [SpeedrunHistoryRow] {
        speedruns.prefix(limit).map { run in
            let pct = SpeedrunRules.accuracy(countries: run.countries, misses: run.misses)
            return SpeedrunHistoryRow(
                id: run.id,
                date: run.date,
                scopeTitle: SpeedrunKey.title(run.scopeRaw),
                timeText: SpeedrunClock.format(run.duration),
                misses: run.misses,
                accuracyText: String(format: "%.0f%%", pct * 100)
            )
        }
    }

    private func summary(for kind: QuizRecordKind) -> StatsKindSummary {
        let rows = quizzes.filter { $0.kind == kind }
        var s = StatsKindSummary()
        s.quizzes = rows.count
        s.correct = rows.reduce(0) { $0 + $1.score }
        s.total = rows.reduce(0) { $0 + $1.total }
        s.byScope = breakdownByScope(rows)
        s.bySubject = breakdownBySubject(rows)
        s.mostMissed = mostMissed(in: rows, limit: 8)
        return s
    }

    private func breakdownByScope(_ rows: [QuizRecord]) -> [StatsBreakdownRow] {
        let order: [StatsScopeKey] = [
            .africa, .asia, .europe, .northAmerica, .southAmerica, .world, .several, .other,
        ]
        var map: [StatsScopeKey: (q: Int, c: Int, t: Int)] = [:]
        for r in rows {
            let key: StatsScopeKey = r.scope == .unknown ? .other : r.scope
            var cur = map[key] ?? (0, 0, 0)
            cur.q += 1
            cur.c += r.score
            cur.t += r.total
            map[key] = cur
        }
        return order.compactMap { key in
            guard let v = map[key], v.q > 0 else { return nil }
            return StatsBreakdownRow(label: key.title, quizzes: v.q, correct: v.c, total: v.t)
        }
    }

    private func breakdownBySubject(_ rows: [QuizRecord]) -> [StatsBreakdownRow] {
        QuizSubject.allCases.compactMap { subject in
            let subset = rows.filter { $0.subject == subject }
            guard !subset.isEmpty else { return nil }
            let c = subset.reduce(0) { $0 + $1.score }
            let t = subset.reduce(0) { $0 + $1.total }
            return StatsBreakdownRow(label: subject.practiceTitle, quizzes: subset.count,
                                     correct: c, total: t)
        }
    }

    private func mostMissed(in rows: [QuizRecord], limit: Int) -> [StatsMissRow] {
        var counts: [String: Int] = [:]
        for r in rows {
            for name in r.missed {
                counts[name, default: 0] += 1
            }
        }
        return counts
            .map { StatsMissRow(name: $0.key, wrong: $0.value) }
            .sorted {
                if $0.wrong != $1.wrong { return $0.wrong > $1.wrong }
                return $0.name < $1.name
            }
            .prefix(limit)
            .map { $0 }
    }

    private func recentHistory(limit: Int) -> [StatsHistoryRow] {
        quizzes.prefix(limit).map { r in
            StatsHistoryRow(
                id: r.id,
                date: r.date,
                kindTitle: r.kind.title,
                subjectTitle: r.subject.practiceTitle,
                scopeTitle: r.scope.title,
                scoreText: "\(r.score)/\(r.total)",
                isPractice: r.kind == .practice
            )
        }
    }

    private func recentDays(limit: Int, now: Date) -> [StatsBreakdownRow] {
        let cal = Calendar.current
        var rows: [StatsBreakdownRow] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        for offset in 0..<limit {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let start = cal.startOfDay(for: day)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            let inDay = quizzes.filter { $0.date >= start && $0.date < end }
            guard !inDay.isEmpty else { continue }
            let c = inDay.reduce(0) { $0 + $1.score }
            let t = inDay.reduce(0) { $0 + $1.total }
            let label = offset == 0 ? "Today" : (offset == 1 ? "Yesterday" : formatter.string(from: day))
            rows.append(StatsBreakdownRow(label: label, quizzes: inDay.count, correct: c, total: t))
        }
        return rows
    }

    // MARK: Account sync

    func exportPayload() -> SyncPayload {
        SyncPayload(quizzes: quizzes, speedruns: speedruns, speedrunBests: speedrunBests, countries: stats)
    }

    /// Replaces local history and bests with a merged payload. Streak and the unlock deck stay as they are.
    func replace(with payload: SyncPayload) {
        var quizzesById: [UUID: QuizRecord] = [:]
        for record in payload.quizzes { quizzesById[record.id] = record }
        quizzes = quizzesById.values.sorted { $0.date > $1.date }
        if quizzes.count > Self.maxQuizRecords { quizzes = Array(quizzes.prefix(Self.maxQuizRecords)) }

        var runsById: [UUID: SpeedrunRecord] = [:]
        for record in payload.speedruns {
            var copy = record
            copy.scopeRaw = SpeedrunKey.canonical(record.scopeRaw)
            runsById[copy.id] = copy
        }
        speedruns = runsById.values.sorted { $0.date > $1.date }
        if speedruns.count > Self.maxSpeedrunRecords {
            speedruns = Array(speedruns.prefix(Self.maxSpeedrunRecords))
        }
        speedrunBests = Self.migratedBests(payload.speedrunBests)
        stats = payload.countries
        applyScopeRepair()
        saveQuizzes()
        saveSpeedruns()
        saveStats()
    }

    /// Rewrites quizzes saved before a place was recorded. Call once the map is loaded,
    /// and again after a sync so the server copy uses the same place keys.
    func repairQuizScopes(world: [Country]) {
        var regionOf: [String: StatsScopeKey] = [:]
        var counts: [StatsScopeKey: Int] = [:]
        var worldCount = 0
        for country in world where country.quizzable {
            let key = StatsScopeKey.from(poolRegions: [country.region])
            regionOf[country.name] = key
            counts[key, default: 0] += 1
            worldCount += 1
        }
        scopeCensus = (regionOf, counts, worldCount)
        applyScopeRepair()
    }

    private func applyScopeRepair() {
        guard let census = scopeCensus else { return }
        var quizChanged = false
        quizzes = quizzes.map { record in
            guard record.scope.needsPlaceRepair else { return record }
            let inferred = StatsScopeKey.infer(missed: record.missed, total: record.total,
                                                regionOf: { census.regionOf[$0] },
                                                counts: census.counts, worldCount: census.worldCount)
            guard inferred.rawValue != record.scopeRaw else { return record }
            quizChanged = true
            var copy = record
            copy.scopeRaw = inferred.rawValue
            return copy
        }
        var runChanged = false
        speedruns = speedruns.map { run in
            guard run.scope.needsPlaceRepair else { return run }
            let inferred = StatsScopeKey.infer(missed: [], total: run.countries,
                                                regionOf: { _ in nil },
                                                counts: census.counts, worldCount: census.worldCount)
            guard inferred.rawValue != run.scopeRaw else { return run }
            runChanged = true
            var copy = run
            copy.scopeRaw = inferred.rawValue
            return copy
        }
        if quizChanged { saveQuizzes() }
        if runChanged { saveSpeedruns() }
    }

    static func previewSnapshot(_ payload: SyncPayload) -> StatsSnapshot {
        let name = "maplock.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
        defaults.removePersistentDomain(forName: name)
        let store = StatsStore(defaults: defaults)
        store.replace(with: payload)
        return store.snapshot(roundText: "")
    }
}

/// Stats a Mac uploads and the worker merges. Dates stay in Apple's JSON date format.
struct SyncPayload: Codable, Equatable {
    var quizzes: [QuizRecord] = []
    var speedruns: [SpeedrunRecord] = []
    var speedrunBests: [String: Double] = [:]
    var countries: [String: CountryStat] = [:]

    /// Union of history, fastest time per region, higher country counts.
    func merged(with other: SyncPayload) -> SyncPayload {
        var quizzesById: [UUID: QuizRecord] = [:]
        for record in quizzes + other.quizzes { quizzesById[record.id] = record }
        var runsById: [UUID: SpeedrunRecord] = [:]
        for record in speedruns + other.speedruns { runsById[record.id] = record }

        var bests: [String: Double] = [:]
        for (key, value) in speedrunBests.merging(other.speedrunBests, uniquingKeysWith: min) where value > 0 {
            let canonical = SpeedrunKey.canonical(key)
            if let current = bests[canonical] {
                bests[canonical] = min(current, value)
            } else {
                bests[canonical] = value
            }
        }

        var countries = self.countries
        for (name, remote) in other.countries {
            if let local = countries[name] {
                countries[name] = local.merged(with: remote)
            } else {
                countries[name] = remote
            }
        }
        return SyncPayload(
            quizzes: quizzesById.values.sorted { $0.date > $1.date },
            speedruns: runsById.values.sorted { $0.date > $1.date },
            speedrunBests: bests,
            countries: countries
        )
    }
}

extension CountryStat {
    func merged(with other: CountryStat) -> CountryStat {
        var result = self
        result.seen = max(seen, other.seen)
        result.correct = max(correct, other.correct)
        result.wrong = max(wrong, other.wrong)
        result.box = max(box, other.box)
        switch (lastSeen, other.lastSeen) {
        case let (left?, right?): result.lastSeen = max(left, right)
        case (nil, let right?): result.lastSeen = right
        default: break
        }
        return result
    }
}
