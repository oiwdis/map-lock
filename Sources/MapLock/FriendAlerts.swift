import UserNotifications

/// Local notifications for friend requests and race invites.
/// Permission is requested when the user signs in, opens Friends, or a race
/// invite poll starts. Not at first launch.
enum FriendAlerts {
    static let raceCategory = "race-invite"
    static let joinAction = "race-join"
    static let declineAction = "race-decline"

    static func registerCategories() {
        let join = UNNotificationAction(identifier: joinAction, title: "Join", options: [.foreground])
        let decline = UNNotificationAction(identifier: declineAction, title: "Decline", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: raceCategory, actions: [join, decline], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func askIfNeeded() async {
        guard AppSettings().friendRequestNotifications else { return }
        await askIfUndecided()
    }

    /// Race invites are time sensitive, so ask even if friend-request alerts are off.
    static func askForRacesIfNeeded() async {
        await askIfUndecided()
    }

    static func canPost() async -> Bool {
        guard AppSettings().friendRequestNotifications else { return false }
        return await alertsAllowed()
    }

    static func canPostRace() async -> Bool {
        await alertsAllowed()
    }

    static func post(id: String, title: String, body: String, category: String? = nil, info: [String: String]? = nil) async {
        guard await canPost() else { return }
        await deliver(id: id, title: title, body: body, category: category, info: info ?? ["maplock": "friends"])
    }

    static func postRace(id: String, title: String, body: String, info: [String: String]) async {
        guard await canPostRace() else { return }
        await deliver(id: id, title: title, body: body, category: raceCategory, info: info)
    }

    private static func askIfUndecided() async {
        let status = await authorizationStatus()
        guard status == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private static func alertsAllowed() async -> Bool {
        let status = await authorizationStatus()
        return status == .authorized || status == .provisional
    }

    private static func deliver(id: String, title: String, body: String, category: String?, info: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
