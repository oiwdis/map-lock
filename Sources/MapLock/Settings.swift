import Foundation

enum QuizMode: String, CaseIterable {
    case multipleChoice = "choice"
    case typing = "type"
    case mixed = "mix"

    var title: String {
        switch self {
        case .multipleChoice: return "Multiple choice"
        case .typing: return "Type the name"
        case .mixed: return "Mix of both"
        }
    }
}

/// What the quiz asks: name the highlighted country, click the named country, or both.
enum QuizType: String, CaseIterable {
    case name = "name"
    case click = "click"
    case mix = "mix"

    var title: String {
        switch self {
        case .name: return "Name the country"
        case .click: return "Click the country"
        case .mix: return "Mix"
        }
    }
}

/// What a question is about. Capitals and Flags are off the default path (Countries).
enum QuizSubject: String, CaseIterable {
    case countries = "countries"
    case capitals = "capitals"
    case flags = "flags"

    var title: String {
        switch self {
        case .countries: return "Countries"
        case .capitals: return "Capitals"
        case .flags: return "Flags"
        }
    }
}

/// How many questions an unlock / schedule quiz asks.
/// How many questions a practice test asks.
enum PracticeLength: String, CaseIterable, Identifiable {
    case ten = "10"
    case twenty = "20"
    case fifty = "50"
    case all = "all"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ten: return "10"
        case .twenty: return "20"
        case .fifty: return "50"
        case .all: return "All"
        }
    }

    func resolve(poolSize: Int) -> Int {
        let n: Int
        switch self {
        case .ten: n = 10
        case .twenty: n = 20
        case .fifty: n = 50
        case .all: n = max(poolSize, 1)
        }
        return min(max(n, 1), max(poolSize, 1))
    }
}

enum QuestionCount: String, CaseIterable {
    case five = "5"
    case ten = "10"
    case twenty = "20"
    case all = "all"

    var title: String {
        switch self {
        case .five: return "5"
        case .ten: return "10"
        case .twenty: return "20"
        case .all: return "All"
        }
    }

    /// Concrete count for a pool size. `all` means every country in the pool.
    func resolve(poolSize: Int) -> Int {
        let n: Int
        switch self {
        case .five: n = 5
        case .ten: n = 10
        case .twenty: n = 20
        case .all: n = max(poolSize, 1)
        }
        return min(max(n, 1), max(poolSize, 1))
    }
}

/// Light (Seterra-like green land on a light blue sea, the default), Dark, or follow macOS.
enum AppearanceMode: String, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match system"
        }
    }
}

/// User choices, saved in UserDefaults.
final class AppSettings {
    private let defaults: UserDefaults

    private enum Keys {
        static let regions = "maplock.regions"
        static let mode = "maplock.mode"
        static let quizType = "maplock.quizType"
        static let subject = "maplock.subject"
        static let quizOnUnlock = "maplock.quizOnUnlock"
        static let quizOnWake = "maplock.quizOnWake"
        static let appearance = "maplock.appearance"
        static let questionCount = "maplock.questionCount"
        static let requirePerfect = "maplock.requirePerfect"
    }

    static let defaultRegions: Set<Region> = [.africa, .asia]

    /// Hard unlock time limit when "require 100%" is on, so a bug can never lock someone out.
    static let perfectTimeLimit: TimeInterval = 10 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var regions: Set<Region> {
        get {
            guard let raw = defaults.stringArray(forKey: Keys.regions) else { return Self.defaultRegions }
            let set = Set(raw.compactMap { Region(rawValue: $0) })
            return set.isEmpty ? Self.defaultRegions : set
        }
        set {
            defaults.set(newValue.map { $0.rawValue }.sorted(), forKey: Keys.regions)
        }
    }

    /// Turns a region on or off. The last region can't be turned off.
    func toggle(_ region: Region) {
        var r = regions
        if r.contains(region) {
            if r.count > 1 { r.remove(region) }
        } else {
            r.insert(region)
        }
        regions = r
    }

    var mode: QuizMode {
        get { QuizMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .mixed }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }

    /// Name the country (the default, same as before) or click it on the map.
    var quizType: QuizType {
        get { QuizType(rawValue: defaults.string(forKey: Keys.quizType) ?? "") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Keys.quizType) }
    }

    /// Countries (default), Capitals, or Flags. Capitals and Flags stay off until chosen.
    var subject: QuizSubject {
        get { QuizSubject(rawValue: defaults.string(forKey: Keys.subject) ?? "") ?? .countries }
        set { defaults.set(newValue.rawValue, forKey: Keys.subject) }
    }

    /// Light is the default.
    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    var quizOnUnlock: Bool {
        get { defaults.object(forKey: Keys.quizOnUnlock) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.quizOnUnlock) }
    }

    /// Also quiz when the Mac wakes from sleep, even if no password unlock follows.
    var quizOnWake: Bool {
        get { defaults.bool(forKey: Keys.quizOnWake) }
        set { defaults.set(newValue, forKey: Keys.quizOnWake) }
    }

    var questionCount: QuestionCount {
        get { QuestionCount(rawValue: defaults.string(forKey: Keys.questionCount) ?? "") ?? .five }
        set { defaults.set(newValue.rawValue, forKey: Keys.questionCount) }
    }

    /// Unlock quizzes keep going until every question in the set is right, or the time limit hits.
    var requirePerfect: Bool {
        get { defaults.bool(forKey: Keys.requirePerfect) }
        set { defaults.set(newValue, forKey: Keys.requirePerfect) }
    }
}
