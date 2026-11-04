import Foundation

/// Where the running Map Lock.app is. Pure logic (no AppKit) so it can be tested anywhere.
/// AppMover.swift uses it to decide whether to offer "Move to Applications".
enum AppLocation: Equatable {
    /// /Applications or a folder inside it.
    case applications
    /// ~/Applications or a folder inside it.
    case userApplications
    /// A read-only App Translocation copy (macOS runs a quarantined download from a random path).
    case translocated
    /// Anywhere else: Downloads, Desktop, a disk image, and so on.
    case elsewhere
    /// Not a .app bundle at all (for example `swift run`). Never offer a move.
    case notAnApp

    /// True when the app should offer to move itself.
    var shouldOfferMove: Bool { self == .translocated || self == .elsewhere }

    /// Sorts a bundle path. `home` is the user's home folder, like /Users/elliot.
    /// The check ignores case because Mac disks usually do too.
    static func classify(_ path: String, home: String) -> AppLocation {
        let p = normalize(path).lowercased()
        guard p.hasSuffix(".app") else { return .notAnApp }
        if p.contains("/apptranslocation/") { return .translocated }
        if isInside(p, "/applications") { return .applications }
        let h = normalize(home).lowercased()
        if h.count > 1, isInside(p, h + "/applications") { return .userApplications }
        return .elsewhere
    }

    /// Removes a trailing slash, "." and ".." parts and double slashes.
    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when `path` is somewhere below `folder` (not the folder itself).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder + "/")
    }
}

/// Builds the commands the mover runs. Pure so the quoting can be tested.
enum MoveCommands {
    /// Wraps text in single quotes for /bin/sh, so spaces and quotes in a path are safe.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Makes an AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The shell command run as admin: check the source is there, replace the old copy,
    /// copy the app, clear quarantine. Fails (non-zero) if the copy fails.
    static func adminShell(source: String, destination: String) -> String {
        let src = shellQuote(source), dst = shellQuote(destination)
        return "/bin/test -d \(src) && /bin/rm -rf \(dst) && /usr/bin/ditto \(src) \(dst) && " +
               "{ /usr/bin/xattr -dr com.apple.quarantine \(dst) 2>/dev/null; true; }"
    }

    /// AppleScript that runs `adminShell` after the Mac's admin password prompt.
    static func adminAppleScript(source: String, destination: String) -> String {
        "do shell script " + appleScriptString(adminShell(source: source, destination: destination)) +
        " with administrator privileges"
    }

    /// Waits for this process to end, then opens the new copy. The path is passed as $1.
    static let relaunchScript = "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$1\""
}
