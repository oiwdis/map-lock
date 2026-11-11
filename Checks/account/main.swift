import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { fails.append(name) }
}

expect("short name", AccountName.problem(with: "ab") != nil)
expect("spaces", AccountName.problem(with: "bad name") != nil)
expect("reserved", AccountName.problem(with: "maplock") != nil)
expect("ok name", AccountName.problem(with: "Ada_1") == nil)

var generator = SeededGenerator(seedHex: "ab12")
let first = SpeedrunRules.shuffled(["Chad", "Mali", "Egypt", "Kenya"], using: &generator)
var again = SeededGenerator(seedHex: "ab12")
expect("seed matches", SpeedrunRules.shuffled(["Chad", "Mali", "Egypt", "Kenya"], using: &again) == first)
expect("seed keeps every country", Set(first) == ["Chad", "Mali", "Egypt", "Kenya"])

let day = Date(timeIntervalSince1970: 1_700_000_000)
let left = SyncPayload(
    quizzes: [QuizRecord(date: day, score: 1, total: 2, duration: 3, missed: [], kind: .practice, subject: .countries, scope: .europe, id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)],
    speedruns: [],
    speedrunBests: ["Europe": 40, "world": 90],
    countries: ["France": CountryStat(seen: 2, correct: 1, wrong: 1, box: 1, lastSeen: day)]
)
let right = SyncPayload(
    quizzes: [QuizRecord(date: day.addingTimeInterval(10), score: 2, total: 2, duration: 4, missed: [], kind: .lock, subject: .countries, scope: .asia, id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)],
    speedruns: [],
    speedrunBests: ["Europe": 25, "countries|click|Europe": 30],
    countries: ["France": CountryStat(seen: 1, correct: 1, wrong: 0, box: 0, lastSeen: day.addingTimeInterval(5))]
)
let merged = left.merged(with: right)
expect("union keeps both quizzes", merged.quizzes.count == 2)
expect("faster europe best migrates and deduplicates", merged.speedrunBests["countries|click|Europe"] == 25)
expect("world best migrates", merged.speedrunBests["countries|click|world"] == 90)
expect("legacy best keys are removed", merged.speedrunBests["Europe"] == nil && merged.speedrunBests["world"] == nil)
expect("country counts take the max", merged.countries["France"]?.seen == 2 && merged.countries["France"]?.wrong == 1)

let suite = "maplock.check.account.tmp"
UserDefaults().removePersistentDomain(forName: suite)
let store = StatsStore(defaults: UserDefaults(suiteName: suite)!)
store.replace(with: merged)
expect("replaced quiz count", store.quizzes.count == 2)
expect("preview best", StatsStore.previewSnapshot(merged).speedrunBests.contains(where: { $0.scopeTitle == "Country / Click map / Europe" && $0.timeText == "00:25.0" }))
expect("world scope", PracticeScope.fromServer("world") == .world)
expect("europe scope", PracticeScope.fromServer("Europe") == .region(.europe))

print(fails.isEmpty ? "account: all pass" : "account FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
