import Foundation

enum QuestionKind {
    case choice
    case typing
}

struct Question {
    let target: Country
    let kind: QuestionKind
    /// Four names for multiple choice (shuffled, includes the answer). Empty for typing.
    let options: [String]
}

enum QuizEngine {
    static let questionsPerSession = 5

    /// Builds one question for a target picked by the deck.
    static func makeQuestion(target: Country, number: Int, world: [Country], mode: QuizMode, stats: StatsStore) -> Question {
        let kind: QuestionKind
        switch mode {
        case .multipleChoice: kind = .choice
        case .typing: kind = .typing
        case .mixed:
            // New or just missed countries start as multiple choice.
            let box = stats.stat(for: target.name)?.box ?? -1
            if box <= 0 { kind = .choice } else { kind = (number % 2 == 0) ? .choice : .typing }
        }
        let options = kind == .choice ? choiceOptions(for: target, world: world) : []
        return Question(target: target, kind: kind, options: options)
    }

    /// The answer plus 3 others from the same continent. Two are nearby countries
    /// (harder to tell apart), one is random.
    static func choiceOptions(for target: Country, world: [Country]) -> [String] {
        let sameRegion = world.filter { $0.quizzable && $0.region == target.region && $0.name != target.name }

        func distance(_ c: Country) -> Double {
            let dx = Double(c.center.x - target.center.x)
            let dy = Double(c.center.y - target.center.y)
            return dx * dx + dy * dy
        }

        let nearby = sameRegion.sorted { distance($0) < distance($1) }.prefix(6).shuffled()
        var chosen: [String] = Array(nearby.prefix(2).map { $0.name })

        var rest = sameRegion.map { $0.name }.filter { !chosen.contains($0) }.shuffled()
        while chosen.count < 3, let next = rest.popLast() {
            chosen.append(next)
        }
        // Tiny regions: borrow from anywhere.
        if chosen.count < 3 {
            var others = world.filter { $0.quizzable && $0.name != target.name && !chosen.contains($0.name) }
                .map { $0.name }.shuffled()
            while chosen.count < 3, let next = others.popLast() {
                chosen.append(next)
            }
        }
        return (chosen + [target.name]).shuffled()
    }
}
