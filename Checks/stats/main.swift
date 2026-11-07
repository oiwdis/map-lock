// Checks expanded StatsStore: records, scope/subject breakdowns, snapshot.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { fails.append(name) }
}

let suite = "maplock.check.stats.tmp"
UserDefaults().removePersistentDomain(forName: suite)
let box = UserDefaults(suiteName: suite)!
let store = StatsStore(defaults: box)

store.record("France", correct: true)
store.record("France", correct: false)
store.record("Chad", correct: false)
expect("country wrong counts", store.stat(for: "France")?.wrong == 1 && store.stat(for: "Chad")?.wrong == 1)
expect("overall accuracy 1/3", abs(store.overallAccuracy - (1.0 / 3.0)) < 0.001)

let day = Date(timeIntervalSince1970: 1_700_000_000)
store.recordQuiz(score: 8, total: 10, duration: 40, missed: ["Chad"], kind: .practice,
                 subject: .flags, scope: .africa, now: day)
store.recordQuiz(score: 4, total: 5, duration: 20, missed: ["France"], kind: .lock,
                 subject: .countries, scope: .asia, now: day.addingTimeInterval(60))
store.recordQuiz(score: 10, total: 10, duration: 30, missed: [], kind: .practice,
                 subject: .capitals, scope: .world, now: day.addingTimeInterval(120))

expect("three quiz records", store.quizzes.count == 3)
expect("best percent 100", abs(store.bestPercent - 1.0) < 0.001)

let snap = store.snapshot(roundText: "3 of 10", now: day.addingTimeInterval(200))
expect("practice quizzes 2", snap.practice.quizzes == 2)
expect("unlock quizzes 1", snap.unlock.quizzes == 1)
expect("practice has flag mode", snap.practice.bySubject.contains(where: { $0.label == "Flag" }))
expect("practice has africa place", snap.practice.byScope.contains(where: { $0.label == "Africa" }))
expect("unlock has asia", snap.unlock.byScope.contains(where: { $0.label == "Asia" }))
expect("history has rows", snap.history.count == 3)
expect("most missed includes Chad", snap.mostMissed.contains(where: { $0.name == "Chad" }))
expect("day history non-empty", !snap.dayHistory.isEmpty)

// Old-record decode (no subjectRaw / scopeRaw)
struct Legacy: Encodable {
    let date: Date
    let score: Int
    let total: Int
    let duration: TimeInterval
    let missed: [String]
    let kind: QuizRecordKind
}
let legacy = Legacy(date: day, score: 1, total: 2, duration: 5, missed: ["X"], kind: .practice)
let data = try! JSONEncoder().encode([legacy])
let decoded = try! JSONDecoder().decode([QuizRecord].self, from: data)
expect("legacy defaults subject", decoded[0].subject == .countries)
expect("legacy defaults scope", decoded[0].scope == .unknown)

expect("scope from world", StatsScopeKey.from(practiceScope: .world) == .world)
expect("scope from region", StatsScopeKey.from(practiceScope: .region(.europe)) == .europe)
expect("scope several", StatsScopeKey.from(poolRegions: [.africa, .asia]) == .several)
expect("scope one", StatsScopeKey.from(poolRegions: [.europe]) == .europe)

print(fails.isEmpty ? "stats: all pass" : "stats FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
