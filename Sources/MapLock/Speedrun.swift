import Foundation

/// Speedrun rules that do not need a window: who is asked, the shuffle, the clock,
/// and what a click does. The country list itself still comes from the shared map,
/// so Russia stays in Asia, Oceania is absent, and places left out of the quiz
/// (Palestine, the seven small Caribbean countries, merged territories) stay out.
enum SpeedrunPool {
    /// Quizzable countries in one continent, or every quizzable country for the whole world.
    static func names(world: [Country], scope: PracticeScope) -> [String] {
        world.compactMap { country in
            guard country.quizzable else { return nil }
            switch scope {
            case .world:
                return country.name
            case .region(let region):
                return country.region == region ? country.name : nil
            }
        }
    }
}

enum SpeedrunRules {
    /// Fisher-Yates. Every name is kept exactly once.
    static func shuffled(_ names: [String], using rng: inout some RandomNumberGenerator) -> [String] {
        var items = names
        guard items.count > 1 else { return items }
        var i = items.count - 1
        while i > 0 {
            let j = Int.random(in: 0...i, using: &rng)
            if i != j { items.swapAt(i, j) }
            i -= 1
        }
        return items
    }

    static func shuffled(_ names: [String]) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return shuffled(names, using: &rng)
    }

    /// Right answers over right answers plus misses. A finished run's "right" count is the country count.
    static func accuracy(countries: Int, misses: Int) -> Double {
        let found = max(countries, 0)
        let wrong = max(misses, 0)
        let denom = found + wrong
        guard denom > 0 else { return 0 }
        return Double(found) / Double(denom)
    }

    /// A strictly faster finish. The first saved time for a place is a best. Zero or junk times are not.
    static func isNewBest(duration: TimeInterval, previous: TimeInterval?) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        guard let previous, previous.isFinite, previous > 0 else { return true }
        return duration < previous
    }
}

/// `mm:ss.t`, tenths floored so the clock does not tick early.
enum SpeedrunClock {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00.0" }
        let tenthsTotal = Int((seconds * 10).rounded(.towardZero))
        let tenths = tenthsTotal % 10
        let whole = tenthsTotal / 10
        let secs = whole % 60
        let mins = whole / 60
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
}

/// One speedrun in progress. Wrong clicks stay on the same country. A right click moves on.
struct SpeedrunProgress: Equatable {
    var order: [String]
    var index: Int = 0
    var misses: Int = 0

    var current: String? {
        order.indices.contains(index) ? order[index] : nil
    }

    var isFinished: Bool { !order.isEmpty && index >= order.count }

    enum ClickResult: Equatable {
        case ignored
        case miss
        case advanced
        case finished
    }

    mutating func click(_ name: String) -> ClickResult {
        guard !name.isEmpty, let current else { return .ignored }
        if name == current {
            index += 1
            return isFinished ? .finished : .advanced
        }
        misses += 1
        return .miss
    }
}
