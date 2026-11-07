import UserNotifications

/// Local notifications for friend requests. Permission is requested only when
/// the user signs in or opens Friends, not at first launch.
enum FriendAlerts {
    static func askIfNeeded() async {
        guard AppSettings().friendRequestNotifications else { return }
        let status = await authorizationStatus()
        guard status == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func canPost() async -> Bool {
        guard AppSettings().friendRequestNotifications else { return false }
        let status = await authorizationStatus()
        return status == .authorized || status == .provisional
    }

    static func post(id: String, title: String, body: String) async {
        guard await canPost() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["maplock": "friends"]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
