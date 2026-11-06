import Foundation

enum QuestionKind {
    case choice
    case typing
    /// The name is shown and the country is clicked on the map.
    case click
}

struct Question {
    let target: Country
    let kind: QuestionKind
    let subject: QuizSubject
    /// Four options for multiple choice (shuffled, includes the answer). Empty for typing and click.
    let options: [String]
    /// The string that counts as the right answer (country name or capital).
    let answer: String
    /// Emoji flag for Flags questions.
    let flagEmoji: String?

    var prompt: String {
        switch (subject, kind) {
        case (.countries, .choice): return "Which country is highlighted?"
        case (.countries, .typing): return "Type the name, then press Return"
        case (.countries, .click): return "Click this country on the map"
        case (.capitals, .choice): return "What is the capital of \(target.name)?"
        case (.capitals, .typing): return "Type the capital of \(target.name)"
        case (.capitals, .click): return "Click \(target.name) on the map"
        case (.flags, .choice): return "Which country is this flag?"
        case (.flags, .typing): return "Type the country for this flag"
        case (.flags, .click): return "Click the country for this flag"
        }
    }
}

enum QuizEngine {
    /// Default when settings are missing.
    static let questionsPerSession = 5

    /// Builds one question for a target picked by the deck.
    static func makeQuestion(target: Country, number: Int, world: [Country], mode: QuizMode,
                             type: QuizType = .name, subject: QuizSubject = .countries,
                             stats: StatsStore) -> Question {
        // Capitals and Flags never use click: there is nothing sensible to click for a capital,
        // and Flags already show the emoji. Fall back to the Name answer style.
        let effectiveType: QuizType = (subject == .countries) ? type : .name

        var nameNumber = number
        switch effectiveType {
        case .name: break
        case .click:
            return Question(target: target, kind: .click, subject: subject, options: [],
                            answer: target.name, flagEmoji: CountryFacts.flagEmoji(for: target.name))
        case .mix:
            if number % 2 == 1 {
                return Question(target: target, kind: .click, subject: subject, options: [],
                                answer: target.name, flagEmoji: CountryFacts.flagEmoji(for: target.name))
            }
            nameNumber = number / 2
        }
        let number = nameNumber
        let kind: QuestionKind
        switch mode {
        case .multipleChoice: kind = .choice
        case .typing: kind = .typing
        case .mixed:
            let box = stats.stat(for: target.name)?.box ?? -1
            if box <= 0 { kind = .choice } else { kind = (number % 2 == 0) ? .choice : .typing }
        }

        switch subject {
        case .countries:
            let options = kind == .choice ? choiceOptions(for: target, world: world) : []
            return Question(target: target, kind: kind, subject: .countries, options: options,
                            answer: target.name, flagEmoji: nil)
        case .capitals:
            let capital = CountryFacts.capital(of: target.name) ?? target.name
            let options = kind == .choice ? capitalOptions(for: target, world: world) : []
            return Question(target: target, kind: kind, subject: .capitals, options: options,
                            answer: capital, flagEmoji: nil)
        case .flags:
            let options = kind == .choice ? choiceOptions(for: target, world: world) : []
            return Question(target: target, kind: kind, subject: .flags, options: options,
                            answer: target.name, flagEmoji: CountryFacts.flagEmoji(for: target.name))
        }
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
        if chosen.count < 3 {
            var others = world.filter { $0.quizzable && $0.name != target.name && !chosen.contains($0.name) }
                .map { $0.name }.shuffled()
            while chosen.count < 3, let next = others.popLast() {
                chosen.append(next)
            }
        }
        return (chosen + [target.name]).shuffled()
    }

    /// Four capital names: the right one plus three others from the same region.
    static func capitalOptions(for target: Country, world: [Country]) -> [String] {
        let right = CountryFacts.capital(of: target.name) ?? target.name
        var chosen: [String] = []
        let same = world.filter { $0.quizzable && $0.region == target.region && $0.name != target.name }.shuffled()
        for c in same {
            guard let cap = CountryFacts.capital(of: c.name), cap != right, !chosen.contains(cap) else { continue }
            chosen.append(cap)
            if chosen.count == 3 { break }
        }
        if chosen.count < 3 {
            for c in world.filter({ $0.quizzable && $0.name != target.name }).shuffled() {
                guard let cap = CountryFacts.capital(of: c.name), cap != right, !chosen.contains(cap) else { continue }
                chosen.append(cap)
                if chosen.count == 3 { break }
            }
        }
        return (chosen + [right]).shuffled()
    }

    /// How many questions a lock quiz should plan for.
    static func plannedCount(setting: QuestionCount, poolSize: Int) -> Int {
        setting.resolve(poolSize: poolSize)
    }
}


/// Pure helpers for the require-perfect / time-limit rules (easy to unit test).
enum QuizRules {
    static func shouldContinue(requirePerfect: Bool, pendingRetryCount: Int,
                               deadline: Date?, now: Date) -> Bool {
        guard requirePerfect, pendingRetryCount > 0 else { return false }
        if let deadline, now >= deadline { return false }
        return true
    }

    static func plannedCount(setting: QuestionCount, poolSize: Int) -> Int {
        setting.resolve(poolSize: poolSize)
    }
}
