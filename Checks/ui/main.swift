import AppKit
import SwiftUI

// The preview binary never reads a real account session or contacts the account API.
// check-ui.sh excludes the production KeychainStore from this build.
enum KeychainStore {
    static func loadSession() async -> String? { nil }
    static func saveSession(_ token: String) {}
    static func deleteSession() {}
}

/// Renders the real SwiftUI views on macOS, without starting lock/schedule observers.
@main
@MainActor
struct UIPreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await renderAll()
                exit(0)
            } catch {
                fputs("UI preview failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    static func renderAll() async throws {
        let app = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let world = try WorldLoader.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        CountryCatalog.all = world
        let suite = "MapLock.UIPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stats = StatsStore(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        let pool = world.filter { $0.quizzable && $0.region == .africa }.map(\.name)
        let model = HomeModel(settings: settings, schedule: ScheduleStore(defaults: defaults),
                              stats: stats, deck: DeckStore(defaults: defaults), pool: { pool })
        let account = AccountModel(stats: stats)
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            for tab in HomeTab.allCases {
                model.homeTab = tab
                try await capture(HomeView(model: model, account: account, chrome: WindowChrome()),
                                  size: NSSize(width: 1040, height: 760),
                                  name: "\(tab.rawValue)-\(suffix)", output: output)
            }
            model.homeTab = .practice
            try await capture(HomeView(model: model, account: account, chrome: WindowChrome()),
                              size: NSSize(width: 1040, height: 760), name: "practice-options-\(suffix)",
                              output: output, scrollToBottom: true)
            try await capture(HomeView(model: model, account: account, chrome: WindowChrome()),
                              size: NSSize(width: 680, height: 460), name: "practice-compact-\(suffix)", output: output)
            for type in [QuizType.name, .click] {
                let session = QuizSession(world: world, pool: pool, mode: .multipleChoice, quizType: type,
                                          stats: stats, deck: DeckStore(defaults: defaults), count: 10,
                                          kind: .practice, mapScope: .region(.africa), recordsResult: false,
                                          onClose: {})
                try await capture(QuizView(session: session), size: NSSize(width: 1040, height: 760),
                                  name: "quiz-\(type.rawValue)-\(suffix)", output: output)
                if type == .name, let question = session.current {
                    session.choose(question.answer)
                    try await capture(QuizView(session: session), size: NSSize(width: 1040, height: 760),
                                      name: "quiz-feedback-\(suffix)", output: output)
                }
            }
        }
    }

    static func capture<Content: View>(_ content: Content, size: NSSize, name: String, output: URL,
                                       scrollToBottom: Bool = false) async throws {
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Map Lock · UI preview"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        hosting.layoutSubtreeIfNeeded()
        if scrollToBottom {
            let scrolls = scrollViews(in: hosting)
            guard let scroll = scrolls.max(by: { $0.bounds.width < $1.bounds.width }),
                  let document = scroll.documentView else {
                throw NSError(domain: "UIPreview", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "No setup scroll view for \(name)"])
            }
            let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "UIPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "No bitmap for \(name)"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UIPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "No PNG for \(name)"])
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("Captured \(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
        window.close()
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

}
