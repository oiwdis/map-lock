import Foundation

enum QuizMode: String, CaseIterable {
    case multipleChoice = "choice"
    case typing = "type"
    case mixed = "mix"

    var title: String {
        switch self {
        case .multipleChoice: return "Multiple choice"
        case .typing: return "Type it"
        case .mixed: return "Mix of both"
        }
    }
}

/// What the unlock quiz asks: name the highlighted place, click it, or both.
enum QuizType: String, CaseIterable {
    case name = "name"
    case click = "click"
    case mix = "mix"

    var title: String {
        switch self {
        case .name: return "Name it"
        case .click: return "Click on the map"
        case .mix: return "Mix"
        }
    }
}

/// What a question is about. Capitals and Flags are off the default path (Countries).
enum QuizSubject: String, CaseIterable, Identifiable {
    case countries = "countries"
    case capitals = "capitals"
    case flags = "flags"

    var id: String { rawValue }

    /// Unlock Settings label.
    var title: String {
        switch self {
        case .countries: return "Countries"
        case .capitals: return "Capitals"
        case .flags: return "Flags"
        }
    }

    /// Practice tab label (singular).
    var practiceTitle: String {
        switch self {
        case .countries: return "Country"
        case .capitals: return "Capital"
        case .flags: return "Flag"
        }
    }

    var practiceSymbol: String {
        switch self {
        case .countries: return "globe.europe.africa"
        case .capitals: return "building.2"
        case .flags: return "flag"
        }
    }
}

/// How you answer in a practice test for one subject (no Mix).
enum PracticeAnswerStyle: String, CaseIterable, Identifiable {
    case multipleChoice = "choice"
    case typeIt = "type"
    case clickMap = "click"

    var id: String { rawValue }

    func title(for subject: QuizSubject) -> String {
        switch (subject, self) {
        case (.countries, .multipleChoice): return "Multiple choice"
        case (.countries, .typeIt): return "Type the name"
        case (.countries, .clickMap): return "Click it on the map"
        case (.flags, .multipleChoice): return "Multiple choice"
        case (.flags, .typeIt): return "Type the country name"
        case (.flags, .clickMap): return "Show the flag, click the country"
        case (.capitals, .multipleChoice): return "Multiple choice"
        case (.capitals, .typeIt): return "Type the capital"
        case (.capitals, .clickMap): return "Click the country on the map"
        }
    }

    func help(for subject: QuizSubject) -> String {
        switch (subject, self) {
        case (.countries, .multipleChoice):
            return "A country is highlighted. Pick its name from four choices."
        case (.countries, .typeIt):
            return "A country is highlighted. Type its name."
        case (.countries, .clickMap):
            return "You see a country name. Click that country on the map."
        case (.flags, .multipleChoice):
            return "You see a flag. Pick the country name from four choices."
        case (.flags, .typeIt):
            return "You see a flag. Type the country name."
        case (.flags, .clickMap):
            return "You see a flag. Click that country on the map."
        case (.capitals, .multipleChoice):
            return "A country is highlighted. Pick its capital from four choices."
        case (.capitals, .typeIt):
            return "A country is highlighted. Type its capital."
        case (.capitals, .clickMap):
            return "You see a capital name. Click that country on the map."
        }
    }

    /// Maps into the engine's QuizMode + QuizType.
    var enginePair: (mode: QuizMode, type: QuizType) {
        switch self {
        case .multipleChoice: return (.multipleChoice, .name)
        case .typeIt: return (.typing, .name)
        case .clickMap: return (.multipleChoice, .click)
        }
    }
}

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
        // Unlock quiz (separate from Practice).
        static let mode = "maplock.mode"
        static let quizType = "maplock.quizType"
        static let subject = "maplock.subject"
        static let quizOnUnlock = "maplock.quizOnUnlock"
        static let quizOnWake = "maplock.quizOnWake"
        static let appearance = "maplock.appearance"
        static let questionCount = "maplock.questionCount"
        static let requirePerfect = "maplock.requirePerfect"
        // Practice tab.
        static let practiceSubject = "maplock.practice.subject"
        static let practiceCountryStyle = "maplock.practice.style.countries"
        static let practiceFlagStyle = "maplock.practice.style.flags"
        static let practiceCapitalStyle = "maplock.practice.style.capitals"
        static let practiceLength = "maplock.practice.length"
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

    // MARK: Unlock quiz

    var mode: QuizMode {
        get { QuizMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .mixed }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }

    var quizType: QuizType {
        get { QuizType(rawValue: defaults.string(forKey: Keys.quizType) ?? "") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Keys.quizType) }
    }

    var subject: QuizSubject {
        get { QuizSubject(rawValue: defaults.string(forKey: Keys.subject) ?? "") ?? .countries }
        set { defaults.set(newValue.rawValue, forKey: Keys.subject) }
    }

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

    // MARK: Practice

    var practiceSubject: QuizSubject {
        get { QuizSubject(rawValue: defaults.string(forKey: Keys.practiceSubject) ?? "") ?? .countries }
        set { defaults.set(newValue.rawValue, forKey: Keys.practiceSubject) }
    }

    var practiceLength: PracticeLength {
        get { PracticeLength(rawValue: defaults.string(forKey: Keys.practiceLength) ?? "") ?? .twenty }
        set { defaults.set(newValue.rawValue, forKey: Keys.practiceLength) }
    }

    func practiceStyle(for subject: QuizSubject) -> PracticeAnswerStyle {
        let key: String
        switch subject {
        case .countries: key = Keys.practiceCountryStyle
        case .flags: key = Keys.practiceFlagStyle
        case .capitals: key = Keys.practiceCapitalStyle
        }
        return PracticeAnswerStyle(rawValue: defaults.string(forKey: key) ?? "") ?? .multipleChoice
    }

    func setPracticeStyle(_ style: PracticeAnswerStyle, for subject: QuizSubject) {
        let key: String
        switch subject {
        case .countries: key = Keys.practiceCountryStyle
        case .flags: key = Keys.practiceFlagStyle
        case .capitals: key = Keys.practiceCapitalStyle
        }
        defaults.set(style.rawValue, forKey: key)
    }

    /// Subject + answer style currently selected on the Practice tab.
    var practiceEngine: (subject: QuizSubject, mode: QuizMode, type: QuizType) {
        let subject = practiceSubject
        let pair = practiceStyle(for: subject).enginePair
        return (subject, pair.mode, pair.type)
    }

    /// Plain-English summary for unlock Settings footer.
    var unlockQuizSummary: String {
        switch (subject, quizType, mode) {
        case (.countries, .name, .multipleChoice):
            return "A country is highlighted. Pick its name."
        case (.countries, .name, .typing):
            return "A country is highlighted. Type its name."
        case (.countries, .name, .mixed):
            return "A country is highlighted. Multiple choice or type it."
        case (.countries, .click, _):
            return "You see a name and click that country on the map."
        case (.countries, .mix, _):
            return "Half name-the-country, half click-the-country."
        case (.capitals, .name, .multipleChoice):
            return "Pick the capital of the highlighted country."
        case (.capitals, .name, .typing):
            return "Type the capital of the highlighted country."
        case (.capitals, .name, .mixed):
            return "Name the capital: multiple choice or type it."
        case (.capitals, .click, _):
            return "You see a capital. Click that country on the map."
        case (.capitals, .mix, _):
            return "Half name-the-capital, half click-the-country."
        case (.flags, .name, .multipleChoice):
            return "You see a flag. Pick the country."
        case (.flags, .name, .typing):
            return "You see a flag. Type the country name."
        case (.flags, .name, .mixed):
            return "You see a flag. Multiple choice or type the country."
        case (.flags, .click, _):
            return "You see a flag. Click that country on the map."
        case (.flags, .mix, _):
            return "Half name-the-flag, half click-the-country."
        }
    }
}
