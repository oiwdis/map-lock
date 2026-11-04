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

/// Saves per-country results and the daily streak in UserDefaults.
final class StatsStore {
    private let defaults: UserDefaults
    private(set) var stats: [String: CountryStat] = [:]

    private enum Keys {
        static let stats = "maplock.stats"
        static let streak = "maplock.streak"
        static let bestStreak = "maplock.bestStreak"
        static let lastDay = "maplock.lastQuizDay"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.stats),
           let decoded = try? JSONDecoder().decode([String: CountryStat].self, from: data) {
            stats = decoded
        }
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: Keys.stats)
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
