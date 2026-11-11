import Foundation

/// A named list of countries the player can quiz again.
struct NamedCustomSet: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var countries: [String]
}

/// The last custom set, plus named sets, kept on this Mac.
enum CustomSets {
    private static let countriesKey = "maplock.customCountries"
    private static let namedKey = "maplock.customNamedSets"
    static let separator = "\u{1f}"

    static func countries() -> [String] {
        UserDefaults.standard.stringArray(forKey: countriesKey) ?? []
    }

    static func saveCountries(_ names: [String]) {
        UserDefaults.standard.set(Array(Set(names)).sorted(), forKey: countriesKey)
    }

    static func namedSets() -> [NamedCustomSet] {
        guard let data = UserDefaults.standard.data(forKey: namedKey),
              let sets = try? JSONDecoder().decode([NamedCustomSet].self, from: data) else { return [] }
        return sets
    }

    static func saveNamed(_ sets: [NamedCustomSet]) {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        UserDefaults.standard.set(data, forKey: namedKey)
    }

    /// Stable speedrun and race key for this exact list.
    static func placeKey(_ names: [String]) -> String {
        "custom:" + names.sorted().joined(separator: separator)
    }

    static func names(in placeKey: String) -> [String] {
        guard placeKey.hasPrefix("custom:") else { return [] }
        let unit = Character("\u{1f}")
        return placeKey.dropFirst("custom:".count).split(separator: unit).map(String.init)
    }

    /// The saved name when the list matches, otherwise "Custom (12 countries)".
    static func displayTitle(countries: [String]) -> String {
        let sorted = countries.sorted()
        if let match = namedSets().first(where: { $0.countries.sorted() == sorted }), !match.name.isEmpty {
            return match.name
        }
        let count = sorted.count
        return count == 1 ? "Custom (1 country)" : "Custom (\(count) countries)"
    }
}
