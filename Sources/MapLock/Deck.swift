import Foundation

/// A shuffled deck of countries that lasts across quizzes (saved in UserDefaults).
///
/// - Every country in the turned on regions comes up once per round, no repeats.
/// - A missed country goes on a review list and comes back 3 to 5 questions later,
///   again and again until it is answered right.
/// - When the deck and the review list are both empty, a new round starts.
/// - Turning a region on adds its countries to the deck, turning it off removes them.
final class DeckStore {
    struct ReviewItem: Codable, Equatable {
        var name: String
        /// Ask again once `asked` reaches this number.
        var due: Int
    }

    private struct State: Codable {
        var deck: [String] = []
        var shown: [String] = []      // shown this round
        var review: [ReviewItem] = []
        var asked: Int = 0            // total questions ever asked
        var round: Int = 0
        var last: String? = nil
    }

    private let defaults: UserDefaults
    private let key = "maplock.deck"
    private var state: State

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    /// Starts the unlock round over. Called when stats are reset.
    func reset() {
        state = State()
        save()
    }

    /// Makes the deck match the countries that can be asked right now.
    func sync(pool: [String]) {
        let poolSet = Set(pool)
        state.deck = state.deck.filter { poolSet.contains($0) }
        state.review = state.review.filter { poolSet.contains($0.name) }

        if state.round == 0 {
            startRound(pool: pool)
            return
        }

        // Newly turned on countries join the deck at random spots.
        let known = Set(state.deck).union(state.shown).union(state.review.map { $0.name })
        for name in pool.shuffled() where !known.contains(name) {
            let spot = Int.random(in: 0...state.deck.count)
            state.deck.insert(name, at: spot)
        }
        save()
    }

    private func startRound(pool: [String]) {
        state.deck = pool.shuffled()
        state.shown = []
        state.round += 1
        // Do not start the new round with the country we just asked.
        if state.deck.count > 1, state.deck.first == state.last {
            state.deck.swapAt(0, state.deck.count - 1)
        }
        save()
    }

    /// The next country to ask. Call `sync(pool:)` first.
    func next(pool: [String]) -> String? {
        guard !pool.isEmpty else { return nil }
        var pick: String? = nil

        // 1. A missed country that is due again.
        let due = state.review.enumerated()
            .filter { $0.element.due <= state.asked && $0.element.name != state.last }
            .min { $0.element.due < $1.element.due }
        if let due = due {
            pick = due.element.name
            state.review.remove(at: due.offset)
        }

        // 2. The next card in the deck.
        if pick == nil, !state.deck.isEmpty {
            let name = state.deck.removeFirst()
            if !state.shown.contains(name) { state.shown.append(name) }
            pick = name
        }

        // 3. Deck is empty but some missed ones are left: ask them now.
        if pick == nil, !state.review.isEmpty {
            let index = state.review.firstIndex { $0.name != state.last } ?? 0
            pick = state.review[index].name
            state.review.remove(at: index)
        }

        // 4. Everything done: new round.
        if pick == nil {
            startRound(pool: pool)
            if !state.deck.isEmpty {
                let name = state.deck.removeFirst()
                state.shown.append(name)
                pick = name
            }
        }

        state.asked += 1
        state.last = pick
        save()
        return pick
    }

    /// Record the answer. Missed countries come back 3 to 5 questions later.
    func answered(_ name: String, correct: Bool) {
        state.review.removeAll { $0.name == name }
        if !correct {
            state.review.append(ReviewItem(name: name, due: state.asked + Int.random(in: 3...5)))
        }
        save()
    }

    /// "Round progress: X of Y" numbers for the current pool.
    func progress(pool: [String]) -> (shown: Int, total: Int) {
        let poolSet = Set(pool)
        let shown = state.shown.filter { poolSet.contains($0) }.count
        return (min(shown, poolSet.count), poolSet.count)
    }

    var reviewCount: Int { state.review.count }
    var round: Int { max(state.round, 1) }
}
