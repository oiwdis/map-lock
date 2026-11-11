import Foundation

/// One stored trackpad or Dock preference, including which host it was read from.
struct SwipePref: Equatable, Codable {
    var domain: String
    var key: String
    var currentHost: Bool
    var stored: Stored

    enum Stored: Equatable, Codable {
        case absent
        case integer(Int)
        case flag(Bool)

        /// A zero or false value is already off. A missing value is handled by the group.
        var isOn: Bool {
            switch self {
            case .absent: return false
            case .integer(let number): return number != 0
            case .flag(let on): return on
            }
        }
    }

    /// Value written while the lock is up.
    var disabled: Stored {
        switch stored {
        case .flag: return .flag(false)
        case .integer: return .integer(0)
        case .absent:
            if key.hasPrefix("show") { return .flag(false) }
            return .integer(0)
        }
    }
}

/// Decides which copies to turn off. macOS 14 reads the trackpad driver domains.
/// macOS 15 also reads the current-host global domain for the same gestures.
/// Mission Control and App Exposé follow the Dock flags, and a ByHost value wins
/// over the any-host value, so both copies are considered.
enum SwipePlan {
    static func toDisable(_ prefs: [SwipePref]) -> [SwipePref] {
        let groups = Dictionary(grouping: prefs, by: { group(of: $0.key) })
        var chosen: [SwipePref] = []
        for key in groups.keys.sorted() {
            guard let members = groups[key] else { continue }
            let enabled = members.filter { $0.stored.isOn }
            if !enabled.isEmpty {
                // Also write the copy macOS reads when that copy was never saved,
                // so a default-on global value cannot keep the swipe alive.
                var picks = enabled
                for member in members where SwipePlan.isCanonicalDefault(member) && !picks.contains(member) {
                    if case .absent = member.stored { picks.append(member) }
                }
                chosen.append(contentsOf: picks)
                continue
            }
            let wroteSomething = members.contains {
                if case .absent = $0.stored { return false }
                return true
            }
            if wroteSomething { continue }
            // Nothing is saved. These gestures ship turned on, so write the
            // copy macOS actually reads and delete it again afterwards.
            chosen.append(contentsOf: members.filter(isCanonicalDefault))
        }
        return chosen
    }

    private static func group(of key: String) -> String {
        if key.contains("Horiz") { return "horiz" }
        if key.contains("Vert") { return "vert" }
        return key
    }

    /// Driver keys live in the any-host domain. The global gesture keys that
    /// take effect on macOS 14 and 15 live in the current-host domain.
    private static func isCanonicalDefault(_ pref: SwipePref) -> Bool {
        if pref.domain == "NSGlobalDomain" { return pref.currentHost }
        return !pref.currentHost
    }
}

/// Turns Space, Mission Control, and App Exposé trackpad swipes off for a lock
/// quiz, then puts the user's values back. The backup is on disk before the
/// first change, so a crash or force quit is undone on the next launch.
enum TrackpadSwipeGuard {
    private static let backupName = "trackpad-swipe-backup.json"

    /// Same key as Settings. On when the user has not chosen.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "maplock.blockTrackpadSwipes") as? Bool ?? true
    }

    /// Read the gestures, save the originals, then disable the ones that are on.
    static func suspend() {
        guard isEnabled else { return }
        if backupExists() { restore() }
        let chosen = SwipePlan.toDisable(readAll())
        guard !chosen.isEmpty else { return }
        do {
            try writeBackup(chosen)
        } catch {
            return
        }
        for pref in chosen {
            write(pref, value: pref.disabled)
        }
        synchronize(chosen)
        restartDock()
    }

    /// Put back the backed-up values and remove the backup. Safe to call twice.
    static func restore() {
        guard let saved = readBackup() else { return }
        for pref in saved {
            write(pref, value: pref.stored)
        }
        synchronize(saved)
        removeBackup()
        restartDock()
    }

    // MARK: Preferences macOS actually consults

    /// Horizontal values of 2 swipe between full-screen apps. 1 is only
    /// swipe-between-pages, and that is still turned off for the lock because
    /// it is the same three-finger gesture family. Vertical values and the Dock
    /// flags are Mission Control and App Exposé.
    private static let specs: [(domain: String, key: String)] = [
        ("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerHorizSwipeGesture"),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFourFingerHorizSwipeGesture"),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerHorizSwipeGesture"),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFourFingerHorizSwipeGesture"),
        ("NSGlobalDomain", "com.apple.trackpad.threeFingerHorizSwipeGesture"),
        ("NSGlobalDomain", "com.apple.trackpad.fourFingerHorizSwipeGesture"),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerVertSwipeGesture"),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFourFingerVertSwipeGesture"),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerVertSwipeGesture"),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFourFingerVertSwipeGesture"),
        ("NSGlobalDomain", "com.apple.trackpad.threeFingerVertSwipeGesture"),
        ("NSGlobalDomain", "com.apple.trackpad.fourFingerVertSwipeGesture"),
        ("com.apple.dock", "showMissionControlGestureEnabled"),
        ("com.apple.dock", "showAppExposeGestureEnabled"),
    ]

    private static func readAll() -> [SwipePref] {
        specs.flatMap { spec in
            [false, true].map { currentHost in
                SwipePref(
                    domain: spec.domain,
                    key: spec.key,
                    currentHost: currentHost,
                    stored: read(domain: spec.domain, key: spec.key, currentHost: currentHost)
                )
            }
        }
    }

    private static func read(domain: String, key: String, currentHost: Bool) -> SwipePref.Stored {
        let host = currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        guard let raw = CFPreferencesCopyValue(key as CFString, domainRef(domain), kCFPreferencesCurrentUser, host) else {
            return .absent
        }
        let object = raw as AnyObject
        let type = CFGetTypeID(object)
        if type == CFBooleanGetTypeID() {
            return .flag((object as? NSNumber)?.boolValue ?? false)
        }
        if type == CFNumberGetTypeID(), let number = object as? NSNumber {
            return .integer(number.intValue)
        }
        return .absent
    }

    private static func write(_ pref: SwipePref, value: SwipePref.Stored) {
        let host = pref.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        let domain = domainRef(pref.domain)
        let key = pref.key as CFString
        switch value {
        case .absent:
            CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, host)
        case .flag(let on):
            let flag: CFBoolean = on ? kCFBooleanTrue : kCFBooleanFalse
            CFPreferencesSetValue(key, flag, domain, kCFPreferencesCurrentUser, host)
        case .integer(let number):
            CFPreferencesSetValue(key, NSNumber(value: number), domain, kCFPreferencesCurrentUser, host)
        }
    }

    private static func synchronize(_ prefs: [SwipePref]) {
        var seen = Set<String>()
        for pref in prefs {
            let token = "\(pref.domain)|\(pref.currentHost)"
            if seen.contains(token) { continue }
            seen.insert(token)
            let host = pref.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
            CFPreferencesSynchronize(domainRef(pref.domain), kCFPreferencesCurrentUser, host)
        }
    }

    private static func domainRef(_ name: String) -> CFString {
        if name == "NSGlobalDomain" { return kCFPreferencesAnyApplication }
        return name as CFString
    }

    // MARK: Backup

    private static func backupURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root.appendingPathComponent("Map Lock", isDirectory: true).appendingPathComponent(backupName)
    }

    private static func backupExists() -> Bool {
        guard let url = backupURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func writeBackup(_ prefs: [SwipePref]) throws {
        guard let url = backupURL() else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: url, options: .atomic)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private static func readBackup() -> [SwipePref]? {
        guard let url = backupURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SwipePref].self, from: data)
    }

    private static func removeBackup() {
        guard let url = backupURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Dock is the process that applies trackpad Space and Mission Control gestures.
    private static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return
        }
        task.waitUntilExit()
    }
}
