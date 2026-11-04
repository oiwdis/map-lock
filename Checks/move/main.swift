// Checks AppLocation.swift: where the app is, and the commands the mover runs.
// Run ./check-move.sh from the project folder.
import Foundation
nonisolated(unsafe) var fails: [String] = []
func expect(_ name: String, _ ok: Bool) { print((ok ? "ok   " : "FAIL ") + name); if !ok { fails.append(name) } }
let home = "/Users/elliot"
let cases: [(String, AppLocation)] = [
    ("/Applications/Map Lock.app", .applications),
    ("/Applications/Map Lock.app/", .applications),
    ("/applications/map lock.app", .applications),
    ("/Applications/Games/Map Lock.app", .applications),
    ("/Applications/../Users/elliot/Downloads/Map Lock.app", .elsewhere),
    ("/Applications Old/Map Lock.app", .elsewhere),
    ("/Users/elliot/Applications/Map Lock.app", .userApplications),
    ("/Users/elliot//Applications/./Map Lock.app", .userApplications),
    ("/Users/other/Applications/Map Lock.app", .elsewhere),
    ("/Users/elliot/Downloads/Map Lock.app", .elsewhere),
    ("/Users/elliot/Downloads/MapLock/Map Lock.app", .elsewhere),
    ("/Users/elliot/Desktop/Map Lock 2.app", .elsewhere),
    ("/Volumes/Map Lock/Map Lock.app", .elsewhere),
    ("/private/var/folders/xy/abc123/T/AppTranslocation/1A2B-3C4D/d/Map Lock.app", .translocated),
    ("/private/var/folders/xy/abc/T/AppTranslocation/X/d/Applications/Map Lock.app", .translocated),
    ("/Users/elliot/code/map-lock/.build/release", .notAnApp),
    ("/Users/elliot/code/map-lock/.build/release/MapLock", .notAnApp),
    ("/Applications", .notAnApp),
]
for (p, want) in cases {
    let got = AppLocation.classify(p, home: home)
    expect("\(p) -> \(got)", got == want)
}
expect("home with slash", AppLocation.classify("/Users/elliot/Applications/Map Lock.app", home: "/Users/elliot/") == .userApplications)
expect("home / ignored", AppLocation.classify("/Applications/x.app", home: "/") == .applications)
expect("offer: elsewhere", AppLocation.elsewhere.shouldOfferMove)
expect("offer: translocated", AppLocation.translocated.shouldOfferMove)
expect("no offer: applications", !AppLocation.applications.shouldOfferMove)
expect("no offer: ~/Applications", !AppLocation.userApplications.shouldOfferMove)
expect("no offer: not an app", !AppLocation.notAnApp.shouldOfferMove)

func sh(_ script: String, _ args: [String] = []) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script] + args
    let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
// Shell quoting survives spaces, quotes, $ and backslashes.
for s in ["/Users/elliot/Downloads/Map Lock.app", "/tmp/it's \"odd\" $HOME `x` \\n.app"] {
    let (_, out) = sh("printf %s " + MoveCommands.shellQuote(s))
    expect("shellQuote \(s)", out == s)
}
// AppleScript string escaping.
expect("applescript escape", MoveCommands.appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
let script = MoveCommands.adminAppleScript(source: "/a b.app", destination: "/Applications/Map Lock.app")
expect("admin script form", script.hasPrefix("do shell script \"") && script.hasSuffix("\" with administrator privileges"))
print(script)

// Admin shell: run it for real with cp -R standing in for ditto (so it also runs without ditto).
let root = NSTemporaryDirectory() + "mvtest-\(getpid())"
let src = root + "/Down loads/Map Lock.app", dst = root + "/Apps/Map Lock.app"
try! FileManager.default.createDirectory(atPath: src + "/Contents", withIntermediateDirectories: true)
_ = FileManager.default.createFile(atPath: src + "/Contents/new", contents: Data())
try! FileManager.default.createDirectory(atPath: dst + "/Contents", withIntermediateDirectories: true)
_ = FileManager.default.createFile(atPath: dst + "/Contents/old", contents: Data())
let cmd = MoveCommands.adminShell(source: src, destination: dst)
    .replacingOccurrences(of: "/usr/bin/ditto", with: "cp -R").replacingOccurrences(of: "/usr/bin/xattr", with: "true")
let (code, _) = sh(cmd)
expect("admin shell copies and replaces", code == 0 && FileManager.default.fileExists(atPath: dst + "/Contents/new")
       && !FileManager.default.fileExists(atPath: dst + "/Contents/old"))
let (code2, _) = sh(MoveCommands.adminShell(source: root + "/missing.app", destination: root + "/Apps/X.app")
    .replacingOccurrences(of: "/usr/bin/ditto", with: "cp -R"))
expect("admin shell fails when copy fails", code2 != 0)

// Relaunch helper: waits for the pid to end, then "opens" the path ($1).
let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1"]; try! sleeper.run()
let marker = root + "/opened"
let relaunch = MoveCommands.relaunchScript.replacingOccurrences(of: "/usr/bin/open -n", with: "touch \"\(marker)\"; echo")
let t0 = Date()
let (_, out) = sh(relaunch, [String(sleeper.processIdentifier), dst])
let waited = Date().timeIntervalSince(t0)
expect("relaunch waits for exit (\(String(format: "%.1f", waited))s) then opens path", waited > 0.8 && out.trimmingCharacters(in: .newlines) == dst
       && FileManager.default.fileExists(atPath: marker))
try? FileManager.default.removeItem(atPath: root)

print(fails.isEmpty ? "move: all pass" : "move FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
