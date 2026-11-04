import AppKit

@main
@MainActor
struct MapLockApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A regular app: it shows in the Dock and can be kept there.
        app.setActivationPolicy(.regular)
        app.run()
        // Keeps the delegate alive for the whole run (NSApplication holds it weakly).
        withExtendedLifetime(delegate) {}
    }
}
