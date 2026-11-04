import Foundation

/// How scheduled quizzes work. "Every unlock" is a separate on/off setting.
enum ScheduleKind: String, CaseIterable {
    case off = "off"
    case fixed = "fixed"
    case random = "random"

    var title: String {
        switch self {
        case .off: return "No set time"
        case .fixed: return "At a set time"
        case .random: return "Random time each day"
        }
    }
}

/// Saves the quiz schedule and decides when a scheduled quiz is due.
/// Times are stored as minutes after midnight (0...1439) in the Mac's time zone.
final class ScheduleStore {
    private let defaults: UserDefaults
    var calendar: Calendar

    private enum Keys {
        static let kind = "maplock.schedule.kind"
        static let times = "maplock.schedule.times"
        static let start = "maplock.schedule.randomStart"
        static let end = "maplock.schedule.randomEnd"
        static let surprise = "maplock.schedule.surprise"
        static let pick = "maplock.schedule.randomPick"
        static let fired = "maplock.schedule.lastFired"
    }

    static let defaultTimes = [16 * 60]
    static let defaultStart = 15 * 60
    static let defaultEnd = 21 * 60

    private struct RandomPick: Codable {
        var day: String
        var minute: Int
    }

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    // MARK: Settings

    var kind: ScheduleKind {
        get { ScheduleKind(rawValue: defaults.string(forKey: Keys.kind) ?? "") ?? .off }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.kind)
            skipPastSlots()
        }
    }

    /// Daily times for "At a set time", sorted, no duplicates.
    var times: [Int] {
        get {
            guard let raw = defaults.array(forKey: Keys.times) as? [Int] else { return Self.defaultTimes }
            let clean = Array(Set(raw.map { Self.clamp($0) })).sorted()
            return clean.isEmpty ? Self.defaultTimes : clean
        }
        set {
            var clean = Array(Set(newValue.map { Self.clamp($0) })).sorted()
            if clean.isEmpty { clean = Self.defaultTimes }
            defaults.set(clean, forKey: Keys.times)
            skipPastSlots()
        }
    }

    var randomStart: Int {
        get { Self.clamp(defaults.object(forKey: Keys.start) as? Int ?? Self.defaultStart) }
        set { setWindow(start: newValue, end: randomEnd) }
    }

    var randomEnd: Int {
        get { Self.clamp(defaults.object(forKey: Keys.end) as? Int ?? Self.defaultEnd) }
        set { setWindow(start: randomStart, end: newValue) }
    }

    var surprise: Bool {
        get { defaults.bool(forKey: Keys.surprise) }
        set { defaults.set(newValue, forKey: Keys.surprise) }
    }

    private func setWindow(start: Int, end: Int) {
        defaults.set(Self.clamp(start), forKey: Keys.start)
        defaults.set(Self.clamp(end), forKey: Keys.end)
        // A new window means a new pick for today.
        defaults.removeObject(forKey: Keys.pick)
        skipPastSlots()
    }

    func addTime(_ minute: Int) { times = times + [minute] }

    func removeTime(_ minute: Int) {
        let rest = times.filter { $0 != minute }
        times = rest.isEmpty ? times : rest
    }

    func replaceTime(_ old: Int, with new: Int) {
        times = times.map { $0 == old ? new : $0 }
    }

    // MARK: Window helpers

    /// The random window, always at least 1 minute long and inside one day.
    var window: (start: Int, end: Int) {
        let s = randomStart
        var e = randomEnd
        if e <= s { e = min(s + 60, 1439) }
        return (s, max(e, s))
    }

    static func clamp(_ m: Int) -> Int { min(max(m, 0), 1439) }

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Today's date at the given minute.
    func date(forMinute m: Int, on day: Date = Date()) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: Self.clamp(m), to: start) ?? start
    }

    // MARK: Random pick

    /// Today's random quiz time. Picked once per day and saved, so a restart does not change it.
    func randomMinute(now: Date = Date()) -> Int {
        let today = dayKey(now)
        if let data = defaults.data(forKey: Keys.pick),
           let pick = try? JSONDecoder().decode(RandomPick.self, from: data),
           pick.day == today {
            return pick.minute
        }
        let w = window
        let nowMinute = minuteOfDay(now)
        var minute: Int
        if nowMinute >= w.end {
            // The window is already over today. Do not quiz right away.
            minute = w.end
            markFired("random", now: now)
        } else {
            // Pick a time that is still ahead of us.
            let low = max(w.start, nowMinute + 1)
            minute = low >= w.end ? w.end : Int.random(in: low...w.end)
        }
        minute = Self.clamp(minute)
        if let data = try? JSONEncoder().encode(RandomPick(day: today, minute: minute)) {
            defaults.set(data, forKey: Keys.pick)
        }
        return minute
    }

    // MARK: Firing

    private var lastFired: [String: String] {
        get { defaults.dictionary(forKey: Keys.fired) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.fired) }
    }

    private func markFired(_ slot: String, now: Date) {
        var f = lastFired
        f[slot] = dayKey(now)
        lastFired = f
    }

    /// All of today's slots as (slot id, minute).
    private func slots(now: Date) -> [(id: String, minute: Int)] {
        switch kind {
        case .off: return []
        case .fixed: return times.map { ("fixed-\($0)", $0) }
        case .random: return [("random", randomMinute(now: now))]
        }
    }

    /// Slots whose time has come today and that have not fired yet today.
    func dueSlots(now: Date = Date()) -> [String] {
        let today = dayKey(now)
        let nowMinute = minuteOfDay(now)
        let all = slots(now: now)
        let fired = lastFired
        return all.filter { $0.minute <= nowMinute && fired[$0.id] != today }.map { $0.id }
    }

    /// Call when a quiz starts for any reason, so a due slot does not fire again right after.
    func markDueAsFired(now: Date = Date()) {
        let due = dueSlots(now: now)
        guard !due.isEmpty else { return }
        var f = lastFired
        let today = dayKey(now)
        for id in due { f[id] = today }
        lastFired = f
    }

    /// After a settings change, times that already passed today wait until tomorrow.
    func skipPastSlots(now: Date = Date()) {
        markDueAsFired(now: now)
    }

    /// The next scheduled quiz time that has not fired yet today, if any.
    func nextToday(now: Date = Date()) -> Int? {
        let today = dayKey(now)
        let all = slots(now: now)
        let fired = lastFired
        return all.filter { fired[$0.id] != today }.map { $0.minute }.min()
    }

    // MARK: Text

    func timeText(_ minute: Int) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date(forMinute: minute))
    }

    /// One line for the home window and the menu.
    func statusText(now: Date = Date()) -> String {
        switch kind {
        case .off:
            return "No scheduled quiz"
        case .fixed:
            if let next = nextToday(now: now) {
                return "Next quiz: \(timeText(next))"
            }
            return "Next quiz: tomorrow at \(timeText(times.first ?? Self.defaultTimes[0]))"
        case .random:
            let w = window
            if nextToday(now: now) == nil {
                return "Today's quiz is done"
            }
            if surprise {
                return "Today's quiz: sometime between \(timeText(w.start)) and \(timeText(w.end))"
            }
            return "Today's quiz: around \(timeText(randomMinute(now: now)))"
        }
    }
}
