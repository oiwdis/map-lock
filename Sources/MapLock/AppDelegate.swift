import AppKit
import Combine
import Sparkle
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let overlay = OverlayController()
    private let practice = PracticeController()
    private let races = RaceController()
    private var account: AccountModel?
    private let settings = AppSettings()
    private let schedule = ScheduleStore()
    private let stats = StatsStore()
    private let deck = DeckStore()
    private var world: [Country] = []
    private var loadError: String? = nil
    private var home: HomeWindowController?
    private let toasts = ChallengeToastController()
    private var toastWatch: AnyCancellable?
    private var scheduleTimer: Timer?
    /// True while the screen is locked, asleep, or another user is active.
    private var isLocked = false
    /// The home window is hidden during a quiz and comes back after.
    private var homeWasVisible = false
    /// True once macOS says it is logging out, restarting or shutting down.
    /// Then a quit is allowed so the Mac never hangs waiting for Map Lock.
    private var systemIsEnding = false
    private var systemEndingReset: Task<Void, Never>?
    /// Set only when Map Lock has moved itself to Applications and is relaunching the new copy.
    /// It is the one case besides log out / restart / shut down where Quit really quits.
    private var allowRealQuit = false
    /// Kept for the life of the app. Sparkle asks about automatic checks on the
    /// second launch because SUEnableAutomaticChecks is not set in Info.plist.
    private var updaterController: SPUStandardUpdaterController?

    private static let launchedBeforeKey = "maplock.launchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        FriendAlerts.registerCategories()
        NSApp.setActivationPolicy(.regular)
        settings.appearance.apply()
        // Before any window, overlay or quiz: offer to move to Applications.
        // If the user says yes, the new copy is starting, so quit this one for real.
        if AppMover.offerMoveIfNeeded() {
            allowRealQuit = true
            NSApp.terminate(nil)
            return
        }
        // Never let macOS close Map Lock by itself when it has no windows open.
        ProcessInfo.processInfo.disableAutomaticTermination("Map Lock waits for the next quiz")
        AnswerSound.warmUp()
        loadWorld()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        setUpMainMenu()
        setUpStatusItem()
        setUpHome()
        setUpObservers()
        startScheduleTimer()

        overlay.onClosed = { [weak self] in
            self?.quizClosed()
        }

        // First launch, Force Quit relaunch, and every cold start: open home.
        // Do not treat app launch as an unlock. Unlock quizzes still run from
        // screen unlock / wake settings, Quiz me now, and the menu.
        UserDefaults.standard.set(true, forKey: Self.launchedBeforeKey)
        home?.show()

        // A due scheduled quiz can still show after launch. Never auto-start
        // an unlock quiz just because Map Lock started.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.checkSchedule()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if overlay.isShowing || practice.isShowing || races.isShowing {
            account?.refreshFriendsFromBackground()
            return
        }
        account?.syncNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon opens the home window (not while a quiz is up).
        if !overlay.isShowing {
            home?.show()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Quit hides the app

    /// Command Q, Quit in the app menu, Quit in the Dock menu and the Quit buttons all end up here.
    /// Map Lock only hides and keeps running, so quizzes still show. Force Quit still stops it.
    /// Log out, restart and shut down are always allowed, and so is the relaunch after
    /// "Move to Applications" (allowRealQuit).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowRealQuit || systemIsEnding || Self.quitComesFromSystem() {
            return .terminateNow
        }
        hideInsteadOfQuitting()
        return .terminateCancel
    }

    private func hideInsteadOfQuitting() {
        // During a quiz the quit is just ignored.
        guard !overlay.isShowing else { return }
        homeWasVisible = false
        home?.hide()
        NSApp.hide(nil)
    }

    /// Looks at the Apple Event that asked us to quit. macOS adds a reason when it is
    /// logging out, restarting or shutting down. A normal quit has no reason.
    private static func quitComesFromSystem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        let keyword = AEKeyword(kAEQuitReason)
        guard let reason = event.attributeDescriptor(forKeyword: keyword)
                ?? event.paramDescriptor(forKeyword: keyword) else { return false }
        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut),
            OSType(kAERestart), OSType(kAEShutDown),
            OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
        ]
        return systemReasons.contains(reason.enumCodeValue) || systemReasons.contains(reason.typeCodeValue)
    }

    @objc private func willPowerOff(_ note: Notification) {
        // Sent when log out, restart or shut down starts.
        systemIsEnding = true
        // If that gets cancelled (for example another app says no), go back to hiding after a while.
        systemEndingReset?.cancel()
        systemEndingReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { self?.systemIsEnding = false }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.close()
    }

    // MARK: Map data

    /// Finds countries.geojson. Inside Map Lock.app it is in Contents/Resources.
    /// With `swift run` it is in the SwiftPM resource bundle next to the binary.
    private func mapDataURL() -> URL? {
        if let url = Bundle.main.url(forResource: "countries", withExtension: "geojson") {
            return url
        }
        // Look for the SwiftPM bundle ourselves first. Bundle.module stops the app if it is missing.
        let bundleName = "MapLock_MapLock.bundle"
        var folders: [URL] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { folders.append(exe) }
        folders.append(Bundle.main.bundleURL)
        if let res = Bundle.main.resourceURL { folders.append(res) }
        let fm = FileManager.default
        for folder in folders {
            let bundleURL = folder.appendingPathComponent(bundleName)
            if let b = Bundle(url: bundleURL), let url = b.url(forResource: "countries", withExtension: "geojson") {
                return url
            }
            let direct = bundleURL.appendingPathComponent("countries.geojson")
            if fm.fileExists(atPath: direct.path) { return direct }
            let nested = bundleURL.appendingPathComponent("Contents/Resources/countries.geojson")
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        // Last resort for `swift run`.
        return Bundle.module.url(forResource: "countries", withExtension: "geojson")
    }

    private func loadWorld() {
        guard let url = mapDataURL() else {
            loadError = "Map data file is missing."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            world = try WorldLoader.parse(data)
            CountryCatalog.all = world
            stats.repairQuizScopes(world: world)
        } catch {
            loadError = "Could not read map data: \(error.localizedDescription)"
        }
    }

    /// Countries that can be asked with the current region choices.
    private var pool: [String] {
        let customNames = CustomSets.countries().filter { name in
            world.contains { $0.quizzable && $0.name == name }
        }
        let useCustom = settings.unlockUsesCustom && customNames.count >= 2
        let regional = world.filter { $0.quizzable && settings.regions.contains($0.region) }.map(\.name)
        if useCustom {
            return Array(Set(customNames).union(regional)).sorted()
        }
        return regional
    }

    // MARK: Quiz

    func startQuiz() {
        guard !overlay.isShowing, !practice.isShowing, !races.isShowing, !world.isEmpty else { return }
        let pool = self.pool
        guard !pool.isEmpty else { return }
        let customNames = CustomSets.countries().filter { name in
            world.contains { $0.quizzable && $0.name == name }
        }
        let useCustom = settings.unlockUsesCustom && customNames.count >= 2
        let mapScope: PracticeScope? = useCustom ? .custom(countries: pool) : nil
        // Any quiz counts for a scheduled time that is due now.
        schedule.markDueAsFired()
        let count = settings.questionCount.resolve(poolSize: pool.count)
        let session = QuizSession(
            world: world, pool: pool, mode: settings.mode,
            quizType: settings.quizType, subject: settings.subject,
            stats: stats, deck: deck, count: count, kind: .lock,
            requirePerfect: settings.requirePerfect,
            timeLimit: AppSettings.perfectTimeLimit,
            mapScope: mapScope
        ) { [weak self] in
            self?.overlay.close()
        }
        homeWasVisible = (home?.isVisible ?? false) && !NSApp.isHidden
        home?.hide()
        // A hidden app shows no windows, so unhide first (the home window stays closed).
        if NSApp.isHidden { NSApp.unhide(nil) }
        overlay.show(session: session)
        if !overlay.isShowing && homeWasVisible {
            homeWasVisible = false
            home?.show()
        }
    }

    /// Practice test: one continent or the whole world, in a normal window (no lock).
    func startPractice(_ scope: PracticeScope, length: PracticeLength = .all) {
        guard !overlay.isShowing, !practice.isShowing, !races.isShowing, !world.isEmpty else { return }
        let pool: [String]
        switch scope {
        case .region(let region):
            pool = world.filter { $0.quizzable && $0.region == region }.map { $0.name }
        case .world:
            pool = world.filter { $0.quizzable }.map { $0.name }
        case .custom(let countries):
            let chosen = Set(countries)
            pool = world.filter { $0.quizzable && chosen.contains($0.name) }.map { $0.name }
        }
        if case .custom = scope, pool.count < 2 { return }
        guard !pool.isEmpty else { return }
        let practiceQuiz = settings.practiceEngine
        let speedrun = settings.practiceSpeedrun(for: practiceQuiz.subject)
        let count = speedrun ? pool.count : length.resolve(poolSize: pool.count)
        let order = speedrun ? SpeedrunRules.shuffled(pool) : nil
        // Own deck for this run so practice does not reshuffle the unlock progress.
        let suite = "maplock.practice.ephemeral"
        if let box = UserDefaults(suiteName: suite) {
            box.removePersistentDomain(forName: suite)
        }
        let practiceDeck = DeckStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let session = QuizSession(
            world: world, pool: pool, mode: practiceQuiz.mode,
            quizType: practiceQuiz.type, subject: practiceQuiz.subject,
            stats: stats, deck: practiceDeck, count: count, kind: .practice,
            requirePerfect: false, mapScope: scope,
            speedrun: speedrun, speedrunStyle: settings.practiceStyle(for: practiceQuiz.subject),
            speedrunOrder: order
        ) { [weak self] in
            self?.practice.close()
        }
        practice.onClosed = { [weak self] in
            self?.account?.syncNow()
            self?.home?.model.reload()
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        practice.show(session: session)
    }

    private func quizClosed() {
        // A time that came up while the quiz was open is covered by that quiz.
        schedule.markDueAsFired()
        account?.syncNow()
        home?.model.reload()
        if homeWasVisible {
            homeWasVisible = false
            home?.show()
        }
    }

    // MARK: Schedule

    private func startScheduleTimer() {
        let timer = Timer(timeInterval: 30, target: self, selector: #selector(timerFired(_:)),
                          userInfo: nil, repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    @objc private func timerFired(_ timer: Timer) {
        checkSchedule()
    }

    /// Shows the quiz if a scheduled time has come today and has not fired yet.
    private func checkSchedule() {
        guard !overlay.isShowing, !practice.isShowing, !races.isShowing, !isLocked, !world.isEmpty else { return }
        if !schedule.dueSlots().isEmpty {
            startQuiz()
        }
        if home?.isVisible == true {
            home?.model.refreshStatus()
        }
    }

    private func checkScheduleSoon() {
        Task { @MainActor [weak self] in
            // Give the desktop a moment to come back.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.checkSchedule()
        }
    }

    // MARK: Lock, unlock, sleep, wake

    private func setUpObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenUnlocked(_:)),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenLocked(_:)),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(willPowerOff(_:)),
                        name: NSWorkspace.willPowerOffNotification, object: nil)
        wnc.addObserver(self, selector: #selector(didWake(_:)),
                        name: NSWorkspace.didWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensSlept(_:)),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensWoke(_:)),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sessionLeft(_:)),
                        name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sessionBack(_:)),
                        name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func screenLocked(_ note: Notification) {
        isLocked = true
    }

    @objc private func screenUnlocked(_ note: Notification) {
        isLocked = false
        if settings.quizOnUnlock {
            Task { @MainActor [weak self] in
                // Give the desktop a moment to come back after unlocking.
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.startQuiz()
            }
        } else {
            checkScheduleSoon()
        }
    }

    @objc private func didWake(_ note: Notification) {
        // If the Mac asks for a password, the lock notice comes too and the check waits for unlock.
        account?.refreshFriendsFromBackground()
        checkScheduleSoon()
        maybeQuizOnWake()
    }

    @objc private func screensSlept(_ note: Notification) {
        // Treat a sleeping screen like a lock until it wakes.
        isLocked = true
    }

    @objc private func screensWoke(_ note: Notification) {
        // The screen is on again. If it is still locked, the lock notice keeps isLocked true.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            if !Self.screenIsLockedNow() { self.isLocked = false }
            self.account?.refreshFriendsFromBackground()
            self.checkSchedule()
            self.maybeQuizOnWake()
        }
    }

    /// Optional "Also on wake from sleep": quiz when the Mac wakes and is not locked.
    /// Skipped when Every unlock will already fire (password wake), so we do not double up.
    private func maybeQuizOnWake() {
        guard settings.quizOnWake else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            guard !self.overlay.isShowing, !self.practice.isShowing else { return }
            guard !Self.screenIsLockedNow() else { return }
            // If unlock quizzes are on and we just unlocked, screenUnlocked already started one.
            if self.settings.quizOnUnlock, self.isLocked { return }
            self.startQuiz()
        }
    }

    @objc private func sessionLeft(_ note: Notification) {
        isLocked = true
    }

    @objc private func sessionBack(_ note: Notification) {
        isLocked = false
        checkScheduleSoon()
    }

    /// Asks the window server if the screen is locked right now.
    private static func screenIsLockedNow() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    // MARK: Home window

    private func setUpHome() {
        let account = AccountModel(stats: stats)
        self.account = account
        account.onShowAccount = { [weak self] in
            self?.home?.model.homeTab = .race
            self?.home?.show()
        }
        account.onOpenRace = { [weak self] ticket, isHost in
            self?.openRace(ticket, isHost: isHost)
        }
        account.onInviteHandled = { [weak self] id in
            self?.toasts.noteHandled(id)
        }
        toasts.onAccept = { [weak self] invite in
            self?.acceptChallenge(invite)
        }
        toasts.onDecline = { [weak self] invite in
            self?.account?.declineInvite(id: invite.id)
        }
        toastWatch = account.$raceInvites.sink { [weak self] invites in
            self?.toasts.sync(invites, live: self?.account?.isSignedIn == true)
        }
        account.onRaceCancelled = { [weak self] in
            self?.races.close()
        }
        account.onStartSpeedrun = { [weak self] choice, subject, style in
            self?.home?.model.showSpeedrunSetup(choice: choice, subject: subject, style: style)
            self?.home?.model.homeTab = .practice
            self?.home?.show()
        }
        let model = HomeModel(settings: settings, schedule: schedule, stats: stats, deck: deck,
                              pool: { [weak self] in self?.pool ?? [] })
        model.onChange = { [weak self] in
            self?.settingsChanged()
        }
        model.onQuizNow = { [weak self] in
            self?.quizNowSoon()
        }
        model.onPractice = { [weak self] scope, length in
            self?.startPractice(scope, length: length)
        }
        home = HomeWindowController(model: model, account: account)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            account?.handle(url)
        }
    }

    private func openRace(_ ticket: RaceTicket, isHost: Bool) {
        guard let scope = ticket.practiceScope,
              let token = account?.sessionToken, let userId = account?.user?.id else { return }
        let session = RaceSession(ticket: ticket, world: world, scope: scope, token: token,
                                  userId: userId, isHost: isHost, stats: stats)
        session.friendNames = account?.friends.friends.compactMap(\.username) ?? []
        session.onCancelled = { [weak self] in
            self?.account?.noteRaceCancelled()
        }
        session.onLeft = { [weak self] code in
            self?.account?.noteLeftRace(code)
        }
        session.onFinished = { [weak self] code in
            self?.account?.noteSawResult(code)
        }
        session.onRematch = { [weak self] ticket in
            self?.account?.rememberRace(ticket)
            self?.openRace(ticket, isHost: true)
        }
        session.onChangeRegion = { [weak self] in
            self?.races.close()
            self?.account?.page = .race
            self?.home?.model.homeTab = .race
            self?.home?.show()
        }
        session.onGiveUp = { [weak self] in
            self?.account?.noteRaceCancelled()
            self?.account?.page = .race
            self?.home?.model.homeTab = .race
            self?.home?.show()
        }
        races.onClosed = { [weak self] in
            self?.account?.syncNow()
            self?.home?.model.reload()
        }
        races.show(session: session)
    }

    private func acceptChallenge(_ invite: RaceInvite) {
        if speedrunInProgress() {
            let alert = NSAlert()
            alert.messageText = "Leave this speedrun?"
            alert.informativeText = "Your time will not be saved."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Leave and join")
            alert.addButton(withTitle: "Stay")
            let window = self.toasts.anchorWindow() ?? NSApp.keyWindow
            let leave = { [weak self] in
                self?.toasts.noteHandled(invite.id)
                self?.leaveForChallenge(invite)
            }
            if let window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        Task { @MainActor in leave() }
                    }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                leave()
            }
            return
        }
        toasts.noteHandled(invite.id)
        leaveForChallenge(invite)
    }

    private func speedrunInProgress() -> Bool {
        if let quiz = overlay.session, quiz.isSpeedrun, quiz.phase == .asking { return true }
        if let quiz = practice.quizInProgress, quiz.isSpeedrun, quiz.phase == .asking { return true }
        if let speedrun = practice.speedrunInProgress, speedrun.phase == .asking { return true }
        if let race = races.liveSession, race.phase == "racing" || race.phase == "countdown" { return true }
        return false
    }

    private func leaveForChallenge(_ invite: RaceInvite) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let race = self.races.liveSession {
                if race.phase == "racing" || race.phase == "countdown" {
                    race.forfeit()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                } else if race.canOfferCancel {
                    if let token = self.account?.sessionToken {
                        try? await AccountClient.cancelRace(code: race.ticket.code, token: token)
                    }
                }
            }
            self.overlay.close()
            self.practice.close()
            self.account?.noteRaceCancelled()
            self.account?.acceptInvite(id: invite.id)
        }
    }

    private func showFriends() {
        showFriendsTab(.friends)
    }

    private func showFriendsTab(_ page: AccountPage) {
        account?.page = page
        home?.model.homeTab = .race
        guard !overlay.isShowing else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        home?.show()
    }

    private func settingsChanged() {
        deck.sync(pool: pool)
    }

    private func quizNowSoon() {
        // Let the menu or button finish first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.startQuiz()
        }
    }

    // MARK: Main menu (app menu, Edit for typing, Window)

    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Map Lock")
        appMenu.addItem(withTitle: "About Map Lock",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updaterController {
            let updates = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
            updates.target = updaterController
            appMenu.addItem(updates)
        }
        appMenu.addItem(.separator())
        let open = NSMenuItem(title: "Open Map Lock", action: #selector(openHome(_:)), keyEquivalent: ",")
        open.target = self
        appMenu.addItem(open)
        let quiz = NSMenuItem(title: "Quiz me now", action: #selector(quizNow(_:)), keyEquivalent: "")
        quiz.target = self
        appMenu.addItem(quiz)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Map Lock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // Command Q stays where people expect it, but it only hides (see applicationShouldTerminate).
        appMenu.addItem(withTitle: "Quit Map Lock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: Menu bar globe

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Map Lock") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Map"
            }
            button.toolTip = "Map Lock"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, state: Bool? = nil,
                        value: String? = nil, indent: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let state { item.state = state ? .on : .off }
        if let value { item.representedObject = value }
        if indent { item.indentationLevel = 1 }
        return item
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = loadError {
            menu.addItem(header(error))
            menu.addItem(.separator())
        }

        let quiz = action("Quiz me now", #selector(quizNow(_:)))
        quiz.isEnabled = !world.isEmpty && !practice.isShowing && !races.isShowing
        menu.addItem(quiz)

        let practiceMenu = NSMenu(title: "Practice test")
        for region in Region.allCases {
            let item = NSMenuItem(title: region.title, action: #selector(practiceRegion(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = region.rawValue
            item.isEnabled = !world.isEmpty && !overlay.isShowing && !practice.isShowing && !races.isShowing
            practiceMenu.addItem(item)
        }
        let worldItem = NSMenuItem(title: "Whole world", action: #selector(practiceWorld(_:)), keyEquivalent: "")
        worldItem.target = self
        worldItem.isEnabled = !world.isEmpty && !overlay.isShowing && !practice.isShowing && !races.isShowing
        practiceMenu.addItem(worldItem)
        let practiceItem = NSMenuItem(title: "Practice test", action: nil, keyEquivalent: "")
        practiceItem.submenu = practiceMenu
        menu.addItem(practiceItem)

        menu.addItem(action("Open Map Lock", #selector(openHome(_:))))
        menu.addItem(.separator())

        menu.addItem(header("Regions"))
        let on = settings.regions
        for region in Region.allCases {
            menu.addItem(action(region.title, #selector(toggleRegion(_:)), state: on.contains(region),
                                value: region.rawValue, indent: true))
        }
        menu.addItem(.separator())

        menu.addItem(header("Unlock quiz type"))
        let currentType = settings.quizType
        for type in QuizType.allCases {
            menu.addItem(action(type.title, #selector(chooseQuizType(_:)), state: type == currentType,
                                value: type.rawValue, indent: true))
        }
        menu.addItem(.separator())

        menu.addItem(header("Appearance"))
        let currentLook = settings.appearance
        for look in AppearanceMode.allCases {
            menu.addItem(action(look.title, #selector(chooseAppearance(_:)), state: look == currentLook,
                                value: look.rawValue, indent: true))
        }
        menu.addItem(.separator())

        menu.addItem(header("Unlock answer style"))
        let current = settings.mode
        for mode in QuizMode.allCases {
            menu.addItem(action(mode.title, #selector(chooseMode(_:)), state: mode == current,
                                value: mode.rawValue, indent: true))
        }
        menu.addItem(.separator())

        menu.addItem(header("Unlock ask about"))
        let currentSubject = settings.subject
        for subject in QuizSubject.allCases {
            menu.addItem(action(subject.title, #selector(chooseSubject(_:)), state: subject == currentSubject,
                                value: subject.rawValue, indent: true))
        }
        menu.addItem(.separator())

        menu.addItem(header("When to quiz"))
        menu.addItem(action("Every unlock", #selector(toggleUnlock(_:)), state: settings.quizOnUnlock, indent: true))
        menu.addItem(action("Also on wake from sleep", #selector(toggleWake(_:)), state: settings.quizOnWake, indent: true))
        let kind = schedule.kind
        for k in ScheduleKind.allCases {
            menu.addItem(action(k.title, #selector(chooseSchedule(_:)), state: k == kind,
                                value: k.rawValue, indent: true))
        }
        if kind != .off {
            let status = header(schedule.statusText())
            status.indentationLevel = 1
            menu.addItem(status)
        }
        menu.addItem(action("Change times...", #selector(openHome(_:)), indent: true))
        menu.addItem(.separator())

        let login = action("Open at login", #selector(toggleLogin(_:)),
                           state: LoginItem.isEnabled || LoginItem.needsApproval)
        login.isEnabled = LoginItem.isAppBundle
        menu.addItem(login)
        if LoginItem.needsApproval {
            menu.addItem(action("Approve in Login Items...", #selector(openLoginItems(_:)), indent: true))
        }
        menu.addItem(.separator())

        let streak = stats.currentStreak()
        menu.addItem(header(streak == 1 ? "Streak: 1 day" : "Streak: \(streak) days"))
        let names = pool
        let progress = deck.progress(pool: names)
        menu.addItem(header("Round progress: \(progress.shown) of \(progress.total)"))
        menu.addItem(header("Known well: \(stats.learnedCount(among: names)) of \(names.count)"))
        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide Map Lock", action: #selector(quit(_:)), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = true
        menu.addItem(hide)
        menu.addItem(header("Keeps running for quizzes"))
    }

    // MARK: Menu actions

    @objc private func quizNow(_ sender: Any?) {
        quizNowSoon()
    }

    @objc private func openHome(_ sender: Any?) {
        guard !overlay.isShowing else { return }
        home?.show()
    }

    @objc private func toggleRegion(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let region = Region(rawValue: raw) else { return }
        settings.toggle(region)
        deck.sync(pool: pool)
        home?.model.reload()
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = QuizMode(rawValue: raw) else { return }
        settings.mode = mode
        home?.model.reload()
    }

    @objc private func chooseQuizType(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let type = QuizType(rawValue: raw) else { return }
        settings.quizType = type
        home?.model.reload()
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let look = AppearanceMode(rawValue: raw) else { return }
        settings.appearance = look
        look.apply()
        home?.model.reload()
    }

    @objc private func toggleUnlock(_ sender: NSMenuItem) {
        settings.quizOnUnlock.toggle()
        home?.model.reload()
    }

    @objc private func toggleWake(_ sender: NSMenuItem) {
        settings.quizOnWake.toggle()
        home?.model.reload()
    }

    @objc private func chooseSubject(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let subject = QuizSubject(rawValue: raw) else { return }
        settings.subject = subject
        home?.model.reload()
    }

    @objc private func practiceRegion(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let region = Region(rawValue: raw) else { return }
        startPractice(.region(region), length: .all)
    }

    @objc private func practiceWorld(_ sender: NSMenuItem) {
        startPractice(.world, length: .all)
    }

    @objc private func chooseSchedule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ScheduleKind(rawValue: raw) else { return }
        schedule.kind = kind
        home?.model.reload()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let turnOn = !(LoginItem.isEnabled || LoginItem.needsApproval)
        if let message = LoginItem.set(turnOn) {
            if message == LoginItem.approvalMessage {
                showApprovalAlert()
            } else {
                showAlert(title: "Open at login", text: message)
            }
        }
        home?.model.reload()
    }

    @objc private func openLoginItems(_ sender: NSMenuItem) {
        LoginItem.openLoginItemsSettings()
    }

    private func showApprovalAlert() {
        let alert = NSAlert()
        alert.messageText = "Approve Map Lock"
        alert.informativeText = LoginItem.approvalMessage
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.openLoginItemsSettings()
        }
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        // Goes through applicationShouldTerminate, which hides the app.
        NSApp.terminate(nil)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        if (info["maplock"] as? String) == "race-invite" {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let kind = info["maplock"] as? String
        let action = response.actionIdentifier
        let inviteId = info["inviteId"] as? String
        Task { @MainActor in
            if kind == "race-invite", let inviteId {
                if action == FriendAlerts.declineAction {
                    self.account?.declineInvite(id: inviteId)
                } else if action != UNNotificationDismissActionIdentifier {
                    self.account?.acceptInvite(id: inviteId)
                }
            } else if kind == "race-result" {
                self.account?.page = .race
                self.showFriendsTab(.race)
            } else if kind == "friends" {
                self.showFriends()
            }
            completionHandler()
        }
    }
}
