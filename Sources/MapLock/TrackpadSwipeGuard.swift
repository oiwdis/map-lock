import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import os

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
///
/// Writing the preference and restarting the Dock is not enough on macOS 26.
/// `activateSettings -u` asks the system to reread them. A session event tap
/// swallows the dock-swipe events themselves, which is what actually stops the
/// gesture while the quiz is up. That tap needs Accessibility permission.
enum TrackpadSwipeGuard {
    private static let log = Logger(subsystem: "com.elliot.maplock", category: "swipe")
    private static let backupName = "trackpad-swipe-backup.json"
    private static let activateSettingsPath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    private static var tapPort: CFMachPort?
    private static var tapSource: CFRunLoopSource?
    /// True while a horizontal or vertical dock swipe is in progress.
    private static var trackingDockSwipe = false
    /// Space the lock was shown on. Used only when the event tap is not active.
    private static var heldSpace: UInt64 = 0
    /// Ignore space changes caused by the Dock restart that applies the prefs.
    private static var holdAfter = Date.distantFuture

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var eventTapActive: Bool { tapPort != nil }

    /// Shows the system Accessibility prompt. The user still turns Map Lock on in System Settings.
    static func promptAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.info("accessibility prompt trusted=\(trusted, privacy: .public)")
    }

    /// Same key as Settings. On when the user has not chosen.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "maplock.blockTrackpadSwipes") as? Bool ?? true
    }

    /// Read the gestures, save the originals, then disable the ones that are on.
    static func suspend() {
        log.info("suspend begin enabled=\(isEnabled, privacy: .public) trusted=\(accessibilityTrusted, privacy: .public)")
        guard isEnabled else { return }
        if backupExists() {
            log.info("suspend found a leftover backup, restoring it first")
            restorePreferences()
        }
        let chosen = SwipePlan.toDisable(readAll())
        if chosen.isEmpty {
            log.info("suspend no gesture prefs needed a change")
        } else {
            do {
                try writeBackup(chosen)
            } catch {
                log.error("suspend backup failed \(error.localizedDescription, privacy: .public)")
                startTap()
                return
            }
            for pref in chosen {
                log.info("disable \(pref.domain, privacy: .public) \(pref.key, privacy: .public) currentHost=\(pref.currentHost, privacy: .public)")
                write(pref, value: pref.disabled)
            }
            synchronize(chosen)
            activateSettings()
            let dock = restartDock()
            log.info("suspend dock restart status=\(dock, privacy: .public)")
        }
        holdAfter = Date().addingTimeInterval(1.5)
        startTap()
    }

    /// Put back the backed-up values and remove the backup. Safe to call twice.
    static func restore() {
        log.info("restore begin tapActive=\(eventTapActive, privacy: .public)")
        stopTap()
        heldSpace = 0
        restorePreferences()
    }

    /// Remember the Space the lock panel was shown on.
    static func noteLockedSpace() {
        heldSpace = activeSpace()
        log.info("held space=\(heldSpace, privacy: .public) tapActive=\(eventTapActive, privacy: .public)")
    }

    /// Move back to the locked Space when a swipe got through. Returns true when it did,
    /// so the caller does not rebuild the shield on the Space the swipe landed on.
    static func holdSpaceIfNeeded() -> Bool {
        guard tapPort == nil else { return false }
        guard Date() >= holdAfter else { return false }
        guard heldSpace != 0 else { return false }
        let now = activeSpace()
        guard now != 0, now != heldSpace else { return false }
        let ok = setActiveSpace(heldSpace)
        log.info("snap back from \(now, privacy: .public) to \(heldSpace, privacy: .public) ok=\(ok, privacy: .public)")
        return ok
    }

    private static func restorePreferences() {
        guard let saved = readBackup() else {
            log.info("restore no preference backup")
            return
        }
        log.info("restore writing \(saved.count, privacy: .public) prefs")
        for pref in saved {
            write(pref, value: pref.stored)
        }
        synchronize(saved)
        removeBackup()
        activateSettings()
        let dock = restartDock()
        log.info("restore dock restart status=\(dock, privacy: .public)")
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

    /// Asks macOS to reread user settings. Dock restart alone does not reload gestures on macOS 26.
    private static func activateSettings() {
        guard FileManager.default.isExecutableFile(atPath: activateSettingsPath) else {
            log.error("activateSettings missing")
            return
        }
        let status = run(activateSettingsPath, ["-u"])
        log.info("activateSettings status=\(status, privacy: .public)")
    }

    /// Dock is restarted as well. On macOS 26 the gesture state still needs activateSettings and the event tap.
    @discardableResult
    private static func restartDock() -> Int32 {
        run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            log.error("run failed \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: Event tap

    /// Session tap, not the HID tap. The HID tap needs root. Accessibility is required to swallow events.
    private static func startTap() {
        stopTap()
        let trusted = accessibilityTrusted
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: swipeTapCallback,
            userInfo: nil
        ) else {
            log.error("event tap create failed trusted=\(trusted, privacy: .public)")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            log.error("event tap source failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        tapSource = source
        trackingDockSwipe = false
        log.info("event tap active trusted=\(trusted, privacy: .public)")
    }

    private static func stopTap() {
        let wasActive = tapPort != nil
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tapPort = nil
        tapSource = nil
        trackingDockSwipe = false
        if wasActive {
            log.info("event tap stopped")
        }
    }

    fileprivate static func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
                log.info("event tap re-enabled type=\(type.rawValue, privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }
        if swallow(type: type, event: event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Dock swipes are type 30 with HID type 23. Motion 1 changes Space. Motion 2 is Mission Control
    /// or App Exposé. Pinch is motion 3 and is left alone so the map can still zoom.
    private static func swallow(type: CGEventType, event: CGEvent) -> Bool {
        let realType = event.getIntegerValueField(field(55))
        let et = realType == 0 ? Int64(type.rawValue) : realType
        if et == 30 && event.getIntegerValueField(field(110)) == 23 {
            let axis = event.getIntegerValueField(field(123))
            guard axis == 1 || axis == 2 else { return false }
            let phase = event.getIntegerValueField(field(132))
            if phase == 1 || phase == 4 || phase == 8 {
                trackingDockSwipe = phase == 1
                log.info("swallow dock swipe axis=\(axis, privacy: .public) phase=\(phase, privacy: .public)")
            } else {
                trackingDockSwipe = true
            }
            return true
        }
        if et == 29 && trackingDockSwipe {
            return true
        }
        return false
    }

    private static func field(_ raw: UInt32) -> CGEventField {
        // Private gesture fields are plain integers. The macOS 26 SDK makes this initializer optional.
        guard let field = CGEventField(rawValue: raw) else {
            preconditionFailure("gesture field \(raw)")
        }
        return field
    }

    // MARK: Space snap-back

    /// Only used when the event tap could not be installed. A real Space change, such as wake,
    /// still moves the lock while the tap is active.
    private static func activeSpace() -> UInt64 {
        typealias Connection = @convention(c) () -> Int32
        typealias GetSpace = @convention(c) (Int32) -> UInt64
        guard let connection: Connection = loadSymbol("CGSMainConnectionID"),
              let get: GetSpace = loadSymbol("CGSGetActiveSpace") else {
            log.error("CGSGetActiveSpace unavailable")
            return 0
        }
        return get(connection())
    }

    private static func setActiveSpace(_ space: UInt64) -> Bool {
        typealias Connection = @convention(c) () -> Int32
        typealias CopyDisplay = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
        typealias SetSpace = @convention(c) (Int32, CFString, UInt64) -> Int32
        guard let connection: Connection = loadSymbol("CGSMainConnectionID"),
              let copy: CopyDisplay = loadSymbol("CGSCopyManagedDisplayForSpace"),
              let set: SetSpace = loadSymbol("CGSManagedDisplaySetCurrentSpace") else {
            log.error("space switch symbols unavailable")
            return false
        }
        let cid = connection()
        guard let display = copy(cid, space)?.takeRetainedValue() else {
            log.error("no display for space \(space, privacy: .public)")
            return false
        }
        let status = set(cid, display, space)
        return status == 0
    }

    private static func loadSymbol<T>(_ name: String) -> T? {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else { continue }
            return unsafeBitCast(symbol, to: T.self)
        }
        return nil
    }
}

private func swipeTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    TrackpadSwipeGuard.handleTap(type: type, event: event)
}
