// Checks speedrun order, clicks, clock format, and saved bests. No AppKit.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { fails.append(name) }
}

struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }
}

var rng = LCG(state: 42)
let names = ["Chad", "Mali", "Egypt", "Kenya", "Ghana"]
let once = SpeedrunRules.shuffled(names, using: &rng)
expect("shuffle keeps each country once", Set(once) == Set(names) && once.count == names.count)
var rng2 = LCG(state: 42)
expect("shuffle is repeatable", SpeedrunRules.shuffled(names, using: &rng2) == once)

expect("clock zero", SpeedrunClock.format(0) == "00:00.0")
expect("clock tenth floored", SpeedrunClock.format(0.19) == "00:00.1")
expect("clock under a tenth stays zero", SpeedrunClock.format(0.09) == "00:00.0")
expect("clock minute", SpeedrunClock.format(65) == "01:05.0")
expect("clock ninety seconds", SpeedrunClock.format(90) == "01:30.0")

expect("accuracy perfect", abs(SpeedrunRules.accuracy(countries: 10, misses: 0) - 1) < 0.001)
expect("accuracy with misses", abs(SpeedrunRules.accuracy(countries: 4, misses: 1) - 0.8) < 0.001)
expect("first time is a best", SpeedrunRules.isNewBest(duration: 12, previous: nil))
expect("faster is a best", SpeedrunRules.isNewBest(duration: 9, previous: 10))
expect("slower is not a best", !SpeedrunRules.isNewBest(duration: 11, previous: 10))
expect("tie is not a best", !SpeedrunRules.isNewBest(duration: 10, previous: 10))
expect("zero is not a best", !SpeedrunRules.isNewBest(duration: 0, previous: nil))

var run = SpeedrunProgress(order: ["France", "Spain"])
expect("wrong stays", run.click("Italy") == .miss && run.current == "France" && run.misses == 1)
expect("second miss counts", run.click("Italy") == .miss && run.misses == 2 && run.current == "France")
expect("right advances", run.click("France") == .advanced && run.current == "Spain" && run.misses == 2)
expect("sea ignored", run.click("") == .ignored && run.misses == 2 && run.current == "Spain")
expect("last country finishes", run.click("Spain") == .finished && run.isFinished)

func country(_ name: String, _ region: Region, quizzable: Bool = true) -> Country {
    let ring = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
    let box = CGRect(x: 0, y: 0, width: 1, height: 1)
    return Country(name: name, region: region, polygons: [[ring]], quizzable: quizzable,
                   rawBounds: box, focusBounds: box)
}

let world = [
    country("France", .europe),
    country("Russia", .asia),
    country("Palestine", .asia, quizzable: false),
    country("Japan", .asia),
    country("Egypt", .africa),
]
let europe = SpeedrunPool.names(world: world, scope: .region(.europe))
let asia = SpeedrunPool.names(world: world, scope: .region(.asia))
let everywhere = SpeedrunPool.names(world: world, scope: .world)
expect("europe is only France", europe == ["France"])
expect("russia stays in asia", asia.contains("Russia") && !europe.contains("Russia"))
expect("palestine is not asked", !asia.contains("Palestine") && !everywhere.contains("Palestine"))
expect("world asks only quizzable countries", Set(everywhere) == ["France", "Russia", "Japan", "Egypt"])

let suite = "maplock.check.speedrun.tmp"
UserDefaults().removePersistentDomain(forName: suite)
let box = UserDefaults(suiteName: suite)!
let store = StatsStore(defaults: box)
let europeKey = SpeedrunKey.make(subject: .countries, style: .clickMap, scope: .europe)
let asiaKey = SpeedrunKey.make(subject: .countries, style: .clickMap, scope: .asia)
let first = store.recordSpeedrun(key: "Europe", duration: 40, misses: 2, countries: 10)
expect("old europe key migrates", first.isNewBest && abs(first.best - 40) < 0.001)
let slower = store.recordSpeedrun(key: europeKey, duration: 55, misses: 0, countries: 10)
expect("slower keeps old best", !slower.isNewBest && abs(slower.best - 40) < 0.001)
let faster = store.recordSpeedrun(key: asiaKey, duration: 20, misses: 1, countries: 8)
expect("other region has its own best", faster.isNewBest && abs(faster.best - 20) < 0.001)
let snap = store.snapshot(roundText: "0 of 0")
expect("europe best shown", snap.speedrunBests.contains(where: { $0.scopeTitle == "Country / Click map / Europe" && $0.timeText == "00:40.0" }))
expect("asia best shown", snap.speedrunBests.contains(where: { $0.scopeTitle == "Country / Click map / Asia" && $0.timeText == "00:20.0" }))
expect("three recent runs", snap.speedrunRuns.count == 3)
expect("recent run is newest", snap.speedrunRuns.first?.scopeTitle == "Country / Click map / Asia")
expect("speedrun is not a practice quiz", snap.practice.quizzes == 0)

print(fails.isEmpty ? "speedrun: all pass" : "speedrun FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
