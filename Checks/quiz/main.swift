import Foundation

nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { fails.append(name) }
}

// Question counts
expect("5 of 100", QuestionCount.five.resolve(poolSize: 100) == 5)
expect("10 of 100", QuestionCount.ten.resolve(poolSize: 100) == 10)
expect("20 of 100", QuestionCount.twenty.resolve(poolSize: 100) == 20)
expect("all of 54", QuestionCount.all.resolve(poolSize: 54) == 54)
expect("5 capped by pool 3", QuestionCount.five.resolve(poolSize: 3) == 3)
expect("all of 0 -> 1", QuestionCount.all.resolve(poolSize: 0) == 1)
expect("practice 10", PracticeLength.ten.resolve(poolSize: 100) == 10)
expect("practice 50 of 40", PracticeLength.fifty.resolve(poolSize: 40) == 40)
expect("practice all", PracticeLength.all.resolve(poolSize: 54) == 54)
expect("africa choice", PracticeChoice.africa.scope == .region(.africa))
expect("world choice", PracticeChoice.world.scope == .world)

// Require-perfect / time limit
let start = Date(timeIntervalSince1970: 1_700_000_000)
let deadline = start.addingTimeInterval(AppSettings.perfectTimeLimit)
expect("continue with misses", QuizRules.shouldContinue(requirePerfect: true, pendingRetryCount: 2, deadline: deadline, now: start))
expect("stop when perfect", !QuizRules.shouldContinue(requirePerfect: true, pendingRetryCount: 0, deadline: deadline, now: start))
expect("stop when off", !QuizRules.shouldContinue(requirePerfect: false, pendingRetryCount: 2, deadline: deadline, now: start))
expect("stop at deadline", !QuizRules.shouldContinue(requirePerfect: true, pendingRetryCount: 2, deadline: deadline, now: deadline))
expect("stop after deadline", !QuizRules.shouldContinue(requirePerfect: true, pendingRetryCount: 2, deadline: deadline, now: deadline.addingTimeInterval(1)))
expect("10 minute limit", AppSettings.perfectTimeLimit == 600)

// Name matching
let names = ["United States", "United Kingdom", "South Korea", "Czechia", "Côte d'Ivoire", "Russia"]
expect("US", AnswerChecker.check("usa", target: "United States", allNames: names) == .correct)
expect("ivory coast", AnswerChecker.check("Ivory Coast", target: "Côte d'Ivoire", allNames: names) == .correct)
expect("czech republic", AnswerChecker.check("Czech Republic", target: "Czechia", allNames: names) == .correct)
expect("wrong country not typo", AnswerChecker.check("United Kingdom", target: "United States", allNames: names) == .wrong)
expect("case/accent", AnswerChecker.check("CÔTE D'IVOIRE", target: "Côte d'Ivoire", allNames: names) == .correct)

// Capitals
expect("paris", AnswerChecker.checkCapital("Paris", country: "France") == .correct)
expect("washington dc", AnswerChecker.checkCapital("Washington DC", country: "United States") == .correct)
expect("kyiv", AnswerChecker.checkCapital("Kiev", country: "Ukraine") == .correct)
expect("wrong capital", AnswerChecker.checkCapital("Paris", country: "Germany") == .wrong)
expect("brasilia accent", AnswerChecker.checkCapital("Brasilia", country: "Brazil") == .correct)

// Facts coverage for a few known countries
for name in ["France", "Japan", "Western Sahara", "Kosovo", "Taiwan", "Russia"] {
    expect("capital \(name)", CountryFacts.capital(of: name) != nil)
    expect("iso \(name)", CountryFacts.iso2[name] != nil)
    expect("flag \(name)", CountryFacts.flagEmoji(for: name) != nil)
}
expect("France flag", CountryFacts.flagEmoji(for: "France") == "🇫🇷")
expect("US flag", CountryFacts.flagEmoji(for: "United States") == "🇺🇸")
expect("facts cover 176", CountryFacts.capitals.count == 176 && CountryFacts.iso2.count == 176)



// Practice answer styles (separate from unlock)
expect("practice country choice pair", PracticeAnswerStyle.multipleChoice.enginePair.type == .name
    && PracticeAnswerStyle.multipleChoice.enginePair.mode == .multipleChoice)
expect("practice click pair", PracticeAnswerStyle.clickMap.enginePair.type == .click)
expect("practice flag click help", PracticeAnswerStyle.clickMap.help(for: .flags).contains("flag"))
expect("practice capital type help", PracticeAnswerStyle.typeIt.help(for: .capitals).contains("capital"))
expect("practice titles", QuizSubject.countries.practiceTitle == "Country"
    && QuizSubject.flags.practiceTitle == "Flag"
    && QuizSubject.capitals.practiceTitle == "Capital")

let unlock = AppSettings(defaults: UserDefaults(suiteName: "maplock.check.quiz.tmp")!)
unlock.subject = .capitals
unlock.quizType = .name
unlock.mode = .multipleChoice
expect("unlock footer capitals choice", unlock.unlockQuizSummary.contains("capital"))
unlock.quizType = .click
expect("unlock footer capitals click", unlock.unlockQuizSummary.contains("Click"))
unlock.subject = .flags
unlock.quizType = .name
unlock.mode = .typing
expect("unlock footer flags type", unlock.unlockQuizSummary.contains("flag"))
unlock.practiceSubject = .flags
unlock.setPracticeStyle(.clickMap, for: .flags)
let eng = unlock.practiceEngine
expect("practice engine subject", eng.subject == .flags && eng.type == .click)


print(fails.isEmpty ? "quiz: all pass" : "quiz FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
