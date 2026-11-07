import Foundation

/// Same username rules as server/src/username.ts. The worker is the source of truth.
enum AccountName {
    static func problem(with raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.range(of: "^[A-Za-z0-9_]{3,20}$", options: .regularExpression) == nil {
            if name.count < 3 || name.count > 20 { return "Usernames are 3 to 20 characters" }
            return "Use letters, numbers, and underscores only"
        }
        let folded = name.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map { Character($0) }
        let letters = String(folded)
        let lower = name.lowercased()
        if reserved.contains(lower) || reserved.contains(letters) { return "That username is reserved" }
        if blocked.contains(where: { letters.contains($0) }) { return "Pick a different username" }
        return nil
    }

    private static let reserved: Set<String> = [
        "admin", "administrator", "support", "maplock", "system", "moderator",
        "mod", "root", "null", "undefined", "friend", "friends",
    ]

    private static let blocked = [
        "fuck", "shit", "bitch", "cunt", "dick", "cock", "piss", "asshole",
        "bastard", "slut", "whore", "nigger", "nigga", "faggot", "fag", "retard",
        "rape", "nazi", "hitler",
    ]
}
