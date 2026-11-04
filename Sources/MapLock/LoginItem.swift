import Foundation
import ServiceManagement

/// "Open at login" using SMAppService (macOS 13 and newer).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// True when running from a real .app bundle. `swift run` cannot be a login item.
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Turns open at login on or off. Returns a short message to show, or nil when all is fine.
    static func set(_ on: Bool) -> String? {
        guard isAppBundle else {
            return "Open at login works when you run Map Lock.app (see build-app.sh)."
        }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            if on && needsApproval { return approvalMessage }
            return "Could not change open at login: \(error.localizedDescription)"
        }
        if on && needsApproval { return approvalMessage }
        return nil
    }

    static let approvalMessage =
        "Almost done. Approve Map Lock in System Settings > General > Login Items."

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
