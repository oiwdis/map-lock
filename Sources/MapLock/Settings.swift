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
        static let quizOnUnlock = "maplock.quizOnUnlock"
        static let appearance = "maplock.appearance"
    }

    static let defaultRegions: Set<Region> = [.africa, .asia]

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

    /// Light is the default.
    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    var quizOnUnlock: Bool {
        get { defaults.object(forKey: Keys.quizOnUnlock) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.quizOnUnlock) }
    }
}
