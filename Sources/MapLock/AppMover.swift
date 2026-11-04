import AppKit

/// "Move Map Lock to Applications?" on launch, like the LetsMove library.
/// Runs before anything else shows. If the user says yes, it copies the app to
/// /Applications (asking for an admin password if needed, or ~/Applications as a
/// last resort), trashes the old copy, starts the new one and quits this one.
@MainActor
enum AppMover {
    static let dontAskKey = "maplock.moveToApplications.dontAsk"
    static let appFileName = "Map Lock.app"

    /// Shows the prompt if needed. Returns true when a relaunch has started; the caller
    /// must then let this process really quit (see AppDelegate.allowRealQuit) and stop setup.
    static func offerMoveIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: dontAskKey) else { return false }

        let running = Bundle.main.bundleURL
        let original = originalURL(of: running)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A translocated copy whose original we found is judged by the original's place.
        let location = AppLocation.classify(original.path, home: home)
        guard location.shouldOfferMove else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Map Lock to Applications?"
        alert.informativeText = "Map Lock works best from your Applications folder. It can move itself there now."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let reply = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: dontAskKey)
        }
        guard reply == .alertFirstButtonReturn else { return false }

        // Copy from the real files, not the read-only translocated mount, when we can.
        let source = FileManager.default.fileExists(atPath: original.path) ? original : running
        guard let destination = install(source) else {
            let fail = NSAlert()
            fail.messageText = "Could not move Map Lock"
            fail.informativeText = "You can drag Map Lock into your Applications folder yourself."
            fail.runModal()
            return false
        }

        // The old copy goes to the Trash. A disk image or other read-only place just stays.
        if source.standardizedFileURL != destination.standardizedFileURL {
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
        return relaunch(destination)
    }

    // MARK: Finding the real app

    /// The path the user actually sees (for example ~/Downloads/Map Lock.app), even when
    /// macOS runs the app from an App Translocation path.
    static func originalURL(of url: URL) -> URL {
        // Boolean SecTranslocateIsTranslocatedURL(CFURLRef, bool *, CFErrorRef *)
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>?,
                                                   UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
        // CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef, CFErrorRef *)  (returns +1)
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return url }
        defer { dlclose(lib) }
        if let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL") {
            let isTranslocated = unsafeBitCast(isSym, to: IsTranslocated.self)
            var flag = false
            if isTranslocated(url as CFURL, &flag, nil) != 0, !flag { return url }
        }
        guard let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let originalPath = unsafeBitCast(sym, to: OriginalPath.self)
        guard let result = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return result as URL
    }

    // MARK: Copying

    /// Copies the app into /Applications, then admin /Applications, then ~/Applications.
    /// Returns where it ended up, or nil if every try failed.
    private static func install(_ source: URL) -> URL? {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let systemDest = system.appendingPathComponent(appFileName)

        if fm.isWritableFile(atPath: system.path), plainCopy(source, to: systemDest) {
            return systemDest
        }
        if adminCopy(source, to: systemDest) {
            return systemDest
        }
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: user, withIntermediateDirectories: true)
        let userDest = user.appendingPathComponent(appFileName)
        if plainCopy(source, to: userDest) {
            return userDest
        }
        return nil
    }

    /// Trashes an old copy at `dest` (quitting it first if it is running), then copies.
    private static func plainCopy(_ source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            quitCopy(at: dest)
            do { try fm.trashItem(at: dest, resultingItemURL: nil) } catch { return false }
        }
        do { try fm.copyItem(at: source, to: dest) } catch { return false }
        removeQuarantine(dest)
        return true
    }

    /// Uses the Mac's admin password prompt when /Applications is not writable.
    private static func adminCopy(_ source: URL, to dest: URL) -> Bool {
        if FileManager.default.fileExists(atPath: dest.path) { quitCopy(at: dest) }
        let text = MoveCommands.adminAppleScript(source: source.path, destination: dest.path)
        guard let script = NSAppleScript(source: text) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil && FileManager.default.fileExists(atPath: dest.path)
    }

    /// An older Map Lock running from `dest` is another process, not this one. Stop it so it can be replaced.
    /// (It hides instead of quitting, so a normal quit would not work.)
    private static func quitCopy(at dest: URL) {
        let me = ProcessInfo.processInfo.processIdentifier
        let target = dest.standardizedFileURL.resolvingSymlinksInPath()
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me &&
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
        for app in others { app.forceTerminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Removes the download quarantine flag from the copy. This only touches an extended
    /// attribute, not the files the signature covers, so a notarized app stays valid.
    private static func removeQuarantine(_ url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    // MARK: Relaunch

    /// Starts a tiny shell that waits for this process to end, then opens the new copy.
    private static func relaunch(_ app: URL) -> Bool {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        // sh -c SCRIPT PID PATH: inside the script $0 is the pid and $1 the path.
        return run("/bin/sh", ["-c", MoveCommands.relaunchScript, pid, app.path], wait: false)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String], wait: Bool = true) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        if wait { p.waitUntilExit() }
        return true
    }
}
