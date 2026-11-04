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

/// User choices, saved in UserDefaults.
final class AppSettings {
    private let defaults: UserDefaults

    private enum Keys {
        static let regions = "maplock.regions"
        static let mode = "maplock.mode"
        static let quizOnUnlock = "maplock.quizOnUnlock"
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

    var quizOnUnlock: Bool {
        get { defaults.object(forKey: Keys.quizOnUnlock) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.quizOnUnlock) }
    }
}
