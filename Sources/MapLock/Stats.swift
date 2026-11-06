import Foundation

/// How well a single country is known.
struct CountryStat: Codable {
    var seen: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    /// Leitner style box: 0 = just missed, 5 = known very well.
    var box: Int = 0
    var lastSeen: Date? = nil
}

enum QuizRecordKind: String, Codable {
    case lock
    case practice
}

/// One finished quiz, for the Stats page.
struct QuizRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var score: Int
    var total: Int
    var duration: TimeInterval
    var missed: [String]
    var kind: QuizRecordKind

    var percent: Double { total == 0 ? 0 : Double(score) / Double(total) }
}

/// Saves per-country results, the daily streak, and recent quiz scores in UserDefaults.
final class StatsStore {
    private let defaults: UserDefaults
    private(set) var stats: [String: CountryStat] = [:]
    private(set) var quizzes: [QuizRecord] = []

    private enum Keys {
        static let stats = "maplock.stats"
        static let streak = "maplock.streak"
        static let bestStreak = "maplock.bestStreak"
        static let lastDay = "maplock.lastQuizDay"
        static let quizzes = "maplock.quizRecords"
        static let bestPercent = "maplock.bestPercent"
        static let bestTime = "maplock.bestTimeSeconds"
    }

    private static let maxQuizRecords = 50

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
        saveStats()
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

    func recordQuiz(score: Int, total: Int, duration: TimeInterval, missed: [String],
                    kind: QuizRecordKind, now: Date = Date()) {
        guard total > 0 else { return }
        let record = QuizRecord(date: now, score: score, total: total, duration: duration,
                                missed: missed, kind: kind)
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
}
