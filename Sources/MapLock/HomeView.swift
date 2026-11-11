import AppKit
import SwiftUI

/// A region switch in the home window.
struct RegionFlag: Identifiable, Equatable {
    let region: Region
    var on: Bool
    var id: String { region.rawValue }
}

/// One daily time for "At a set time".
struct TimeSlot: Identifiable, Equatable {
    let id = UUID()
    var date: Date
}

/// Sidebar pages in the home window (macOS HIG: sidebar navigation).
enum HomeTab: String, CaseIterable, Identifiable, Hashable {
    case practice
    case race
    case stats
    case account
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .practice: return "Practice"
        case .race: return "Race"
        case .stats: return "Stats"
        case .account: return "Account"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .practice: return "map"
        case .race: return "flag.checkered"
        case .stats: return "chart.bar"
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

/// Everything the home window shows. Changes are saved right away.
@MainActor
final class HomeModel: ObservableObject {
    private let settings: AppSettings
    private let schedule: ScheduleStore
    private let stats: StatsStore
    private let deck: DeckStore
    private let poolProvider: () -> [String]
    private var loading = false

    /// Called after a setting changes, so the app can resync (deck, timer, menu).
    var onChange: () -> Void = {}
    var onQuizNow: () -> Void = {}
    /// Practice test for one continent or the whole world (no lock).
    var onPractice: (PracticeScope, PracticeLength) -> Void = { _, _ in }
    var onShowStats: () -> Void = {}

    @Published var mode: QuizMode = .mixed {
        didSet { if !loading { settings.mode = mode; onChange() } }
    }
    @Published var quizType: QuizType = .name {
        didSet { if !loading { settings.quizType = quizType; onChange() } }
    }
    @Published var appearance: AppearanceMode = .light {
        didSet { if !loading { settings.appearance = appearance; appearance.apply(); onChange() } }
    }

    @Published var regionFlags: [RegionFlag] = [] {
        didSet {
            guard !loading else { return }
            let on = Set(regionFlags.filter { $0.on }.map { $0.region })
            let customCovers = unlockUsesCustom && CustomSets.countries().count >= 2
            if on.isEmpty && !customCovers {
                regionFlags = oldValue
                return
            }
            settings.regions = on
            onChange()
            refreshNumbers()
        }
    }

    @Published var quizOnUnlock = true {
        didSet { if !loading { settings.quizOnUnlock = quizOnUnlock; onChange() } }
    }

    @Published var quizOnWake = false {
        didSet { if !loading { settings.quizOnWake = quizOnWake; onChange() } }
    }

    @Published var answerSounds = true {
        didSet { if !loading { settings.answerSounds = answerSounds; onChange() } }
    }

    @Published var friendRequestNotifications = true {
        didSet { if !loading { settings.friendRequestNotifications = friendRequestNotifications; onChange() } }
    }

    @Published var cursorPrompt = true {
        didSet { if !loading { settings.cursorPrompt = cursorPrompt; onChange() } }
    }

    @Published var blockTrackpadSwipes = true {
        didSet { if !loading { settings.blockTrackpadSwipes = blockTrackpadSwipes; onChange() } }
    }

    @Published var questionCount: QuestionCount = .five {
        didSet { if !loading { settings.questionCount = questionCount; onChange() } }
    }

    @Published var requirePerfect = false {
        didSet { if !loading { settings.requirePerfect = requirePerfect; onChange() } }
    }

    @Published var unlockUsesCustom = false {
        didSet {
            guard !loading else { return }
            settings.unlockUsesCustom = unlockUsesCustom
            let customCovers = unlockUsesCustom && CustomSets.countries().count >= 2
            if !customCovers && settings.regions.isEmpty {
                loading = true
                regionFlags = Region.allCases.map { RegionFlag(region: $0, on: $0 == .africa) }
                loading = false
                settings.regions = [.africa]
            }
            onChange()
        }
    }

    /// Bumps when the custom country set changes, so the start buttons refresh.
    @Published var customRevision = 0

    @Published var subject: QuizSubject = .countries {
        didSet { if !loading { settings.subject = subject; onChange() } }
    }

    @Published private(set) var bestPercentText = ""
    @Published private(set) var bestTimeText = ""
    @Published private(set) var mostMissedText = ""
    @Published private(set) var mostMissedLines: [StatsMissRow] = []
    @Published private(set) var statsSnapshot = StatsSnapshot()

    /// Practice pane: selected continent/world (does not start until Start practice).
    @Published var practiceChoice: PracticeChoice = .africa
    @Published var practiceLength: PracticeLength = .twenty {
        didSet { if !loading { settings.practiceLength = practiceLength } }
    }
    @Published var practiceSubject: QuizSubject = .countries {
        didSet { if !loading { settings.practiceSubject = practiceSubject; onChange() } }
    }
    @Published var practiceAnswerStyle: PracticeAnswerStyle = .multipleChoice {
        didSet {
            guard !loading else { return }
            settings.setPracticeStyle(practiceAnswerStyle, for: practiceSubject)
            onChange()
        }
    }
    @Published var practiceSpeedrun = false {
        didSet { if !loading { settings.setPracticeSpeedrun(practiceSpeedrun, for: practiceSubject) } }
    }
    @Published var homeTab: HomeTab = .practice

    @Published var scheduleKind: ScheduleKind = .off {
        didSet { if !loading { schedule.kind = scheduleKind; scheduleChanged() } }
    }

    @Published var fixedSlots: [TimeSlot] = [] {
        didSet {
            guard !loading else { return }
            schedule.times = fixedSlots.map { schedule.minuteOfDay($0.date) }
            scheduleChanged()
        }
    }

    @Published var randomStart = Date() {
        didSet { if !loading { schedule.randomStart = schedule.minuteOfDay(randomStart); scheduleChanged() } }
    }

    @Published var randomEnd = Date() {
        didSet { if !loading { schedule.randomEnd = schedule.minuteOfDay(randomEnd); scheduleChanged() } }
    }

    @Published var surprise = false {
        didSet { if !loading { schedule.surprise = surprise; scheduleChanged() } }
    }

    @Published var openAtLogin = false {
        didSet {
            guard !loading else { return }
            loginMessage = LoginItem.set(openAtLogin)
            if !LoginItem.isAppBundle {
                loading = true
                openAtLogin = false
                loading = false
            }
            onChange()
        }
    }

    @Published private(set) var loginMessage: String? = nil
    @Published private(set) var statusText = ""
    @Published private(set) var windowWarning: String? = nil
    @Published private(set) var streak = 0
    @Published private(set) var roundText = ""

    init(settings: AppSettings, schedule: ScheduleStore, stats: StatsStore, deck: DeckStore,
         pool: @escaping () -> [String]) {
        self.settings = settings
        self.schedule = schedule
        self.stats = stats
        self.deck = deck
        self.poolProvider = pool
        reload()
    }

    /// Reads everything again from the stores (for example after a menu change or a quiz).
    func resetPracticeStats() {
        stats.reset()
        deck.reset()
        onChange()
        refreshNumbers()
    }

    func reload() {
        loading = true
        mode = settings.mode
        quizType = settings.quizType
        appearance = settings.appearance
        let on = settings.regions
        regionFlags = Region.allCases.map { RegionFlag(region: $0, on: on.contains($0)) }
        quizOnUnlock = settings.quizOnUnlock
        quizOnWake = settings.quizOnWake
        answerSounds = settings.answerSounds
        friendRequestNotifications = settings.friendRequestNotifications
        cursorPrompt = settings.cursorPrompt
        blockTrackpadSwipes = settings.blockTrackpadSwipes
        questionCount = settings.questionCount
        requirePerfect = settings.requirePerfect
        unlockUsesCustom = settings.unlockUsesCustom
        subject = settings.subject
        practiceSubject = settings.practiceSubject
        practiceAnswerStyle = settings.practiceStyle(for: settings.practiceSubject)
        practiceLength = settings.practiceLength
        practiceSpeedrun = settings.practiceSpeedrun(for: settings.practiceSubject)
        scheduleKind = schedule.kind
        fixedSlots = schedule.times.map { TimeSlot(date: schedule.date(forMinute: $0)) }
        randomStart = schedule.date(forMinute: schedule.randomStart)
        randomEnd = schedule.date(forMinute: schedule.randomEnd)
        surprise = schedule.surprise
        openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        loading = false

        if LoginItem.needsApproval {
            loginMessage = LoginItem.approvalMessage
        } else if loginMessage == LoginItem.approvalMessage {
            loginMessage = nil
        }
        refreshNumbers()
        refreshStatus()
    }

    func refreshNumbers() {
        streak = stats.currentStreak()
        let p = deck.progress(pool: poolProvider())
        roundText = "\(p.shown) of \(p.total)"
        statsSnapshot = stats.snapshot(roundText: roundText)
        bestPercentText = statsSnapshot.bestPercentText
        bestTimeText = statsSnapshot.bestTimeText
        mostMissedLines = statsSnapshot.mostMissed
        mostMissedText = mostMissedLines.isEmpty
            ? "-" : mostMissedLines.prefix(3).map(\.name).joined(separator: ", ")
    }

    func refreshStatus() {
        statusText = schedule.statusText()
        windowWarning = schedule.randomEnd <= schedule.randomStart
            ? "The end time should be after the start time." : nil
    }

    private func scheduleChanged() {
        refreshStatus()
        onChange()
    }

    func addTime() {
        let used = Set(fixedSlots.map { schedule.minuteOfDay($0.date) })
        var minute = (used.max() ?? (15 * 60)) + 60
        if minute > 1439 { minute = 9 * 60 }
        while used.contains(minute) && minute < 1439 { minute += 1 }
        fixedSlots.append(TimeSlot(date: schedule.date(forMinute: minute)))
    }

    func removeTime(_ id: UUID) {
        guard fixedSlots.count > 1 else { return }
        fixedSlots.removeAll { $0.id == id }
    }

    func startPracticeNow() {
        guard canStartPractice else { return }
        onPractice(practiceChoice.scope, practiceLength)
    }

    var canStartPractice: Bool {
        if practiceChoice == .custom {
            return CustomSets.countries().count >= 2
        }
        return true
    }

    /// Opens Practice with Speedrun on, ready for this place and answer method.
    func showSpeedrunSetup(choice: PracticeChoice, subject: QuizSubject, style: PracticeAnswerStyle) {
        loading = true
        practiceChoice = choice
        practiceSubject = subject
        practiceAnswerStyle = style
        practiceSpeedrun = true
        loading = false
        settings.practiceSubject = subject
        settings.setPracticeStyle(style, for: subject)
        settings.setPracticeSpeedrun(true, for: subject)
        onChange()
    }

    /// Switching practice subject loads that subject's saved answer style and Speedrun switch.
    func selectPracticeSubject(_ subject: QuizSubject) {
        if practiceSubject == subject { return }
        loading = true
        practiceSubject = subject
        practiceAnswerStyle = settings.practiceStyle(for: subject)
        practiceSpeedrun = settings.practiceSpeedrun(for: subject)
        loading = false
        settings.practiceSubject = subject
        onChange()
    }

    func selectPracticeAnswerStyle(_ style: PracticeAnswerStyle) {
        practiceAnswerStyle = style
    }

    var practiceHelpText: String {
        practiceAnswerStyle.help(for: practiceSubject)
    }

    var settingsUnlockSummary: String { settings.unlockQuizSummary }

    var practicePoolHint: String {
        let place: String
        switch practiceChoice.scope {
        case .world: place = "Every included country (no Oceania)."
        case .region(let r): place = "Only \(r.title): that continent map and countries only."
        case .custom:
            let names = CustomSets.countries()
            place = names.count < 2
                ? "Pick at least 2 countries."
                : "\(CustomSets.displayTitle(countries: names)). Only those countries."
        }
        if practiceSpeedrun {
            return place + " Speedrun asks each one once."
        }
        return place
    }

    var canUseLoginItem: Bool { LoginItem.isAppBundle }
    var needsApproval: Bool { LoginItem.needsApproval }

    func openLoginItems() { LoginItem.openLoginItemsSettings() }
}

// MARK: Window

/// Height of the titlebar and toolbar that covers the top of the content view.
/// The scroll views are placed below this band, so they cannot draw behind it.
final class WindowChrome: ObservableObject {
    @Published var toolbarOverlap: CGFloat = 0
}

/// How far toolbar controls hang over a content view, in points.
/// `contentLayoutRect` stops at the old titlebar. Liquid Glass capsules hang lower than that,
/// so the band is the bottom of the lowest real toolbar control.
enum ToolbarBand {
    static func overlap(of view: NSView) -> CGFloat {
        guard let window = view.window, let theme = window.contentView?.superview else { return 0 }
        let hostTop = view.convert(view.bounds, to: theme).maxY
        var lowest = theme.convert(window.contentLayoutRect, from: nil).maxY
        func visit(_ candidate: NSView) {
            if let content = window.contentView, candidate === content || candidate.isDescendant(of: content) {
                return
            }
            let name = NSStringFromClass(type(of: candidate))
            let frame = candidate.convert(candidate.bounds, to: theme)
            let control = name.contains("Toolbar") || name.contains("Titlebar") || name.contains("Button")
            if control, frame.width >= 12, frame.height >= 10, frame.height <= 140, frame.maxY >= hostTop - 12 {
                lowest = min(lowest, frame.minY)
            }
            for sub in candidate.subviews {
                visit(sub)
            }
        }
        visit(theme)
        return max(0, hostTop - lowest + 6)
    }
}

/// Hosting view that keeps the home panes out of the transparent unified toolbar.
final class HomeHostingView: NSHostingView<HomeView> {
    weak var chrome: WindowChrome?
    private var overlapUpdateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarOverlap()
    }

    override func layout() {
        super.layout()
        refreshToolbarOverlap()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshToolbarOverlap()
    }

    /// Clicks in the toolbar band belong to the AppKit toolbar, not the pane underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard window != nil, let chrome else { return super.hitTest(point) }
        let inWindow = convert(point, to: nil)
        let top = convert(bounds, to: nil).maxY
        if inWindow.y >= top - chrome.toolbarOverlap - 0.5 { return nil }
        return super.hitTest(point)
    }

    func refreshToolbarOverlap() {
        guard window != nil, chrome != nil, !overlapUpdateScheduled else { return }
        overlapUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlapUpdateScheduled = false
            guard let chrome = self.chrome else { return }
            let overlap = ToolbarBand.overlap(of: self)
            if abs(chrome.toolbarOverlap - overlap) > 0.5 {
                chrome.toolbarOverlap = overlap
            }
        }
    }
}

/// Quiz and speedrun windows use the same measurement so a glass titlebar cannot cover the question.
final class TitlebarSafeHostingView<Content: View>: NSHostingView<Content> {
    private var extraTop: CGFloat = 0

    override var safeAreaInsets: NSEdgeInsets {
        var insets = super.safeAreaInsets
        insets.top = max(insets.top, extraTop)
        return insets
    }

    override func layout() {
        super.layout()
        let next = ToolbarBand.overlap(of: self)
        guard abs(next - extraTop) > 0.5 else { return }
        extraTop = next
        needsLayout = true
    }
}

@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    let model: HomeModel
    let account: AccountModel
    private let chrome = WindowChrome()
    private var window: NSWindow?

    init(model: HomeModel, account: AccountModel) {
        self.model = model
        self.account = account
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        model.reload()
        if window == nil {
            let frame = Self.fittedFrame()
            let w = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Map Lock"
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.windowBackground
            w.minSize = NSSize(width: 680, height: 460)
            w.styleMask.remove(.fullSizeContentView)
            w.titlebarAppearsTransparent = false
            w.titlebarSeparatorStyle = .automatic
            // Unified style lives on the window. windowToolbarStyle is a Scene modifier.
            w.toolbarStyle = .unified
            let hosting = HomeHostingView(rootView: HomeView(model: model, account: account, chrome: chrome))
            hosting.chrome = chrome
            hosting.safeAreaRegions = .all
            w.contentView = hosting
            account.presentationWindow = w
            w.setFrame(frame, display: false)
            _ = w.setFrameAutosaveName("MapLockHome")
            w.delegate = self
            window = w
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Room for setup and its persistent action, while fitting smaller displays.
    private static func fittedFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1040, max(680, screen.width * 0.82))
        let height = min(780, max(460, screen.height * 0.86))
        let w = min(width, screen.width - 40)
        let h = min(height, screen.height - 40)
        return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: Root view (sidebar + detail)

struct HomeView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject var account: AccountModel
    @ObservedObject var chrome: WindowChrome

    var body: some View {
        VStack(spacing: 0) {
            // Not inside a scroll view. Pane content is clipped at this band's bottom edge,
            // so it cannot draw behind the glass toolbar buttons.
            Color(nsColor: .windowBackgroundColor)
                .frame(height: chrome.toolbarOverlap)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            NavigationSplitView {
                List(selection: $model.homeTab) {
                    Section {
                        ForEach(HomeTab.allCases) { tab in
                            HStack(spacing: Theme.Space.s2) {
                                Label {
                                    Text(tab.title)
                                } icon: {
                                    if model.homeTab == tab {
                                        Image(systemName: tab.symbol)
                                    } else {
                                        Image(systemName: tab.symbol)
                                            .foregroundStyle(Theme.text2)
                                    }
                                }
                                Spacer(minLength: 4)
                                if tab == .race && account.raceInvites.count > 0 {
                                    FriendCountBadge(count: account.raceInvites.count, noun: "race invites")
                                }
                                if tab == .account && account.incomingFriendCount > 0 {
                                    FriendCountBadge(count: account.incomingFriendCount, noun: "friend requests")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .overlay(HitTarget { model.homeTab = tab })
                            .tag(tab)
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top) {
                    HStack(spacing: 10) {
                        AppBadge(size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Map Lock").font(Theme.font(Theme.Size.body, .bold))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.s4)
                }
                // Keep system label colors so the selected row gets white (or vibrancy) on the blue highlight.
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)
            .navigationSplitViewStyle(.balanced)
            // Do not set foregroundStyle on the split view: it paints sidebar labels dark on the selection fill.
            // No preferredColorScheme: NSApp.appearance drives Light / Dark / Match system.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.onQuizNow()
                    } label: {
                        Label("Unlock quiz", systemImage: "lock.open")
                    }
                    .help("Start a screen-locking quiz using your Unlock quiz settings")
                }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.homeTab {
        case .practice:
            PracticePane(model: model)
        case .race:
            AccountPane(account: account, home: model, showsRace: true)
        case .stats:
            StatsPane(model: model, onResetStats: {
                account.markStatsReset()
                model.resetPracticeStats()
                Task { await account.forgetSyncedStats() }
            })
        case .account:
            AccountPane(account: account, home: model)
        case .settings:
            SettingsPane(model: model, onResetStats: {
                account.markStatsReset()
                model.resetPracticeStats()
                Task { await account.forgetSyncedStats() }
            })
        }
    }
}

// MARK: Practice

private struct PracticePane: View {
    @ObservedObject var model: HomeModel
    @State private var editingCustom = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s3)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s6) {
                header
                SetupSection(number: "1", title: "Choose your destination") {
                    whereSection
                }
                SetupSection(number: "2", title: "Make it your practice") {
                    modeSection
                }
                SetupSection(number: "3", title: "Set your pace") {
                    paceSection
                }
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            launchBar
        }
        .sheet(isPresented: $editingCustom) {
            CustomSetEditor { model.customRevision += 1 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            PageHeading(title: "Practice")
            HStack(spacing: Theme.Space.s2) {
                Pill {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.warn)
                    Text(model.streak > 0 ? "\(model.streak) day streak" : "No streak")
                }
                Pill {
                    Image(systemName: "lock.open").foregroundStyle(Theme.accent)
                    Text("No screen lock")
                }
            }
        }
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            LazyVGrid(columns: columns, spacing: Theme.Space.s3) {
                ForEach(PracticeChoice.allCases) { choice in
                    PracticePlaceCard(title: choice.title, symbol: symbol(for: choice),
                                      selected: model.practiceChoice == choice) {
                        model.practiceChoice = choice
                        if choice == .custom, CustomSets.countries().count < 2 {
                            editingCustom = true
                        }
                    }
                }
            }
            if model.practiceChoice == .custom {
                CustomSetSummary { editingCustom = true }
                    .id(model.customRevision)
            }
            Text(model.practicePoolHint)
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s2) {
                ForEach(QuizSubject.allCases) { subject in
                    PracticeModeChip(title: subject.title, symbol: subject.practiceSymbol,
                                     selected: model.practiceSubject == subject) {
                        model.selectPracticeSubject(subject)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s1) {
                SectionLabel("Answer method")
                ForEach(PracticeAnswerStyle.allCases) { style in
                    PracticeAnswerRow(title: style.title(for: model.practiceSubject),
                                      selected: model.practiceAnswerStyle == style) {
                        model.selectPracticeAnswerStyle(style)
                    }
                }
            }
            Label(model.practiceHelpText, systemImage: "info.circle")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var paceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Toggle(isOn: $model.practiceSpeedrun) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Speedrun", systemImage: "timer")
                        .font(Theme.font(Theme.Size.body, .semibold))
                    Text("Every country once. Timer on, no pause between questions.")
                        .font(Theme.font(Theme.Size.sm))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if !model.practiceSpeedrun {
                Divider()
                Picker("Questions", selection: $model.practiceLength) {
                    ForEach(PracticeLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var launchBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s5) {
                sessionSummary
                Spacer(minLength: 0)
                startButton
            }
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                sessionSummary
                startButton
            }
        }
        .padding(.horizontal, Theme.Space.s6)
        .padding(.vertical, Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline2).frame(height: 1) }
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.practiceChoice.title)
                .font(Theme.font(Theme.Size.body, .semibold))
                .foregroundStyle(Theme.text)
            Text(model.canStartPractice
                 ? "\(model.practiceSubject.title) · \(model.practiceSpeedrun ? "Every country" : model.practiceLength.title + " questions")"
                 : "Choose at least 2 countries to begin.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(model.canStartPractice ? Theme.text2 : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startButton: some View {
        Button { model.startPracticeNow() } label: {
            Label(model.practiceSpeedrun ? "Start speedrun" : "Start practice",
                  systemImage: model.practiceSpeedrun ? "timer" : "arrow.right")
        }
        .buttonStyle(AppButtonStyle(kind: .primary, height: 44))
        .disabled(!model.canStartPractice)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Start this session (⌘Return). Practice never locks your screen.")
    }

    private func symbol(for choice: PracticeChoice) -> String {
        switch choice {
        case .africa, .europe: return "globe.europe.africa"
        case .asia: return "globe.asia.australia"
        case .northAmerica, .southAmerica: return "globe.americas"
        case .world: return "globe"
        case .custom: return "checklist"
        }
    }
}

private struct PracticeModeChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HitButton(action: action) {
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Color.white : Theme.text)
            .padding(.horizontal, Theme.Space.s3)
            .padding(.vertical, Theme.Space.s2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.accentFill : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accentFill : Theme.hairline2, lineWidth: selected ? 1.5 : 1)
            )
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PracticeAnswerRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HitButton(action: action) {
            HStack(spacing: Theme.Space.s3) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.text3)
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s3)
            .frame(minHeight: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(selected ? Theme.accent.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PracticePlaceCard: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HitButton(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Theme.accent : Theme.text3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Space.s3)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.08) : Theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline2, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Stats

private struct StatsPane: View {
    @ObservedObject var model: HomeModel
    var onResetStats: () -> Void = {}
    @State private var confirmReset = false

    private var snap: StatsSnapshot { model.statsSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: "Stats")
                .frame(maxWidth: 600, alignment: .leading)
                .padding(Theme.Space.s6)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
            Form {
                if !snap.practice.hasData && !snap.unlock.hasData && snap.speedrunRuns.isEmpty {
                    Section {
                        LearningEmptyState(symbol: "chart.bar.xaxis", title: "No stats yet",
                                           message: "Finish a practice test to see numbers here.")
                        Button("Set up a practice session") { model.homeTab = .practice }
                            .buttonStyle(AppButtonStyle(fullWidth: true))
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: Theme.Space.s3) {
                        StatOverviewCard(title: "Accuracy", value: snap.overallAccuracyText,
                                         symbol: "target", help: "Right answers out of every question asked")
                        StatOverviewCard(title: "Questions", value: snap.totalQuestionsText,
                                         symbol: "questionmark.circle", help: "Practice and unlock combined")
                        StatOverviewCard(title: "Streak", value: snap.currentStreakText,
                                         symbol: "flame.fill", help: "Days in a row with a finished quiz")
                        StatOverviewCard(title: "Best streak", value: snap.bestStreakText,
                                         symbol: "flame", help: "Your longest streak on this Mac")
                    }
                    .listRowInsets(EdgeInsets(top: Theme.Space.s3, leading: Theme.Space.s3,
                                              bottom: Theme.Space.s3, trailing: Theme.Space.s3))
                    .listRowBackground(Color.clear)

                    HStack(spacing: Theme.Space.s3) {
                        StatMiniPill(title: "Best score", value: snap.bestPercentText, symbol: "star.fill")
                        StatMiniPill(title: "Best time", value: snap.bestTimeText, symbol: "timer")
                        StatMiniPill(title: "Round", value: snap.roundText, symbol: "arrow.triangle.2.circlepath")
                    }
                    .listRowInsets(EdgeInsets(top: Theme.Space.s2, leading: Theme.Space.s3,
                                              bottom: Theme.Space.s3, trailing: Theme.Space.s3))
                    .listRowBackground(Color.clear)
                } header: {
                    HStack {
                        Text("Overview")
                        Spacer()
                        Menu {
                            Button("Reset stats…", role: .destructive) { confirmReset = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text2)
                        }
                        .accessibilityLabel("Stats options")
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                } footer: {
                    Text("Practice and unlock quizzes both count here. Sign in from Account to sync your progress.")
                }

                kindSection(title: "Practice", summary: snap.practice, empty: "Finish a practice test to see numbers here.")
                kindSection(title: "Unlock", summary: snap.unlock, empty: "Finish an unlock quiz to see numbers here.", unlock: true)

                Section {
                    ForEach(snap.speedrunBests) { row in
                        HStack {
                            Text(row.scopeTitle)
                            Spacer()
                            Text(row.timeText)
                                .foregroundStyle(row.timeText == "-" ? Theme.text3 : Theme.text)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Label("Speedrun bests", systemImage: "timer")
                } footer: {
                    Text("Fastest time for each place, including time penalties for misses.")
                }

                Section {
                    if snap.speedrunRuns.isEmpty {
                        Text("No speedruns yet.")
                            .foregroundStyle(Theme.text2)
                    } else {
                        ForEach(snap.speedrunRuns) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.scopeTitle)
                                        .font(Theme.font(Theme.Size.sm, .semibold))
                                    Spacer()
                                    Text(row.timeText)
                                        .font(Theme.font(Theme.Size.body, .semibold))
                                        .monospacedDigit()
                                }
                                HStack {
                                    Text(row.misses == 1 ? "1 miss" : "\(row.misses) misses")
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                    Text("·")
                                        .foregroundStyle(Theme.text3)
                                    Text(row.accuracyText)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                        .monospacedDigit()
                                    Spacer()
                                    Text(row.date, style: .date)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                    Text(row.date, style: .time)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Label("Recent speedruns", systemImage: "stopwatch")
                } footer: {
                    Text("Newest first. Time, misses, and accuracy. Up to the last 12 runs.")
                }

                Section {
                    if snap.mostMissed.isEmpty {
                        Text("No misses yet.")
                            .foregroundStyle(Theme.text2)
                    } else {
                        ForEach(snap.mostMissed, id: \.name) { row in
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text("\(row.wrong)")
                                    .foregroundStyle(Theme.text2)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Label("Most missed", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("Countries you got wrong the most, across practice and unlock.")
                }

                Section {
                    if snap.dayHistory.isEmpty {
                        Text("No recent days yet.")
                            .foregroundStyle(Theme.text2)
                    } else {
                        ForEach(snap.dayHistory) { row in
                            HStack {
                                Text(row.label)
                                Spacer()
                                Text(row.percentText)
                                    .foregroundStyle(Theme.text2)
                                    .monospacedDigit()
                                Text(row.detailText)
                                    .font(Theme.font(Theme.Size.xs))
                                    .foregroundStyle(Theme.text3)
                                    .frame(minWidth: 120, alignment: .trailing)
                            }
                        }
                    }
                } header: {
                    Label("Recent days", systemImage: "calendar")
                } footer: {
                    Text("Days you finished at least one quiz.")
                }

                Section {
                    if snap.history.isEmpty {
                        Text("No quiz history yet.")
                            .foregroundStyle(Theme.text2)
                    } else {
                        ForEach(snap.history) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.kindTitle)
                                        .font(Theme.font(Theme.Size.sm, .semibold))
                                        .foregroundStyle(row.isPractice ? Theme.accent : Theme.text2)
                                    Text("·")
                                        .foregroundStyle(Theme.text3)
                                    Text(row.subjectTitle)
                                        .foregroundStyle(Theme.text2)
                                    Spacer()
                                    Text(row.scoreText)
                                        .font(Theme.font(Theme.Size.body, .semibold))
                                        .monospacedDigit()
                                }
                                HStack {
                                    Text(row.scopeTitle)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                    Spacer()
                                    Text(row.date, style: .date)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                    Text(row.date, style: .time)
                                        .font(Theme.font(Theme.Size.xs))
                                        .foregroundStyle(Theme.text3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Label("Recent quizzes", systemImage: "clock")
                } footer: {
                    Text("Newest first. Up to the last 12 finished quizzes.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(
            "Reset stats?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset stats", role: .destructive) { onResetStats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes practice and unlock scores, the daily streak, the current unlock round, and speedrun personal bests on this Mac. A signed-in account loses that copy too, so it does not come back on the next sync. Race history and friends stay.")
        }
    }

    @ViewBuilder
    private func kindSection(title: String, summary: StatsKindSummary, empty: String, unlock: Bool = false) -> some View {
        Section {
            if !summary.hasData {
                Text(empty)
                    .foregroundStyle(Theme.text2)
            } else {
                HStack {
                    StatInlineMetric(title: "Accuracy", value: summary.percentText)
                    Divider()
                    StatInlineMetric(title: "Quizzes", value: "\(summary.quizzes)")
                    Divider()
                    StatInlineMetric(title: "Questions", value: "\(summary.total)")
                }
                .padding(.vertical, Theme.Space.s1)

                if unlock {
                    if !summary.byContinent.isEmpty {
                        Text("By place")
                            .font(Theme.font(Theme.Size.xs, .semibold))
                            .foregroundStyle(Theme.text3)
                            .padding(.top, Theme.Space.s1)
                        ForEach(summary.byContinent) { row in
                            breakdownRow(row)
                        }
                    }
                    if let note = summary.continentNote {
                        Text(note)
                            .font(Theme.font(Theme.Size.xs))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summary.byType.isEmpty {
                        Text("By type")
                            .font(Theme.font(Theme.Size.xs, .semibold))
                            .foregroundStyle(Theme.text3)
                            .padding(.top, Theme.Space.s2)
                        ForEach(summary.byType) { row in
                            breakdownRow(row)
                        }
                    }
                } else if !summary.byScope.isEmpty {
                    Text("By place")
                        .font(Theme.font(Theme.Size.xs, .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(.top, Theme.Space.s1)
                    ForEach(summary.byScope) { row in
                        breakdownRow(row)
                    }
                }

                if !unlock, !summary.bySubject.isEmpty {
                    Text("By mode")
                        .font(Theme.font(Theme.Size.xs, .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(.top, Theme.Space.s2)
                    ForEach(summary.bySubject) { row in
                        breakdownRow(row)
                    }
                }

                if !summary.mostMissed.isEmpty {
                    Text("Most missed here")
                        .font(Theme.font(Theme.Size.xs, .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(.top, Theme.Space.s2)
                    ForEach(summary.mostMissed, id: \.name) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text("\(row.wrong)")
                                .foregroundStyle(Theme.text2)
                                .monospacedDigit()
                        }
                    }
                }
            }
        } header: {
            Text(title)
        }
    }

    private func breakdownRow(_ row: StatsBreakdownRow) -> some View {
        HStack {
            Text(row.label)
            Spacer()
            Text(row.percentText)
                .foregroundStyle(Theme.text2)
                .monospacedDigit()
            Text(row.detailText)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
                .frame(minWidth: 130, alignment: .trailing)
        }
    }
}

private struct StatOverviewCard: View {
    let title: String
    let value: String
    let symbol: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Label(title, systemImage: symbol)
                .font(Theme.font(Theme.Size.xs, .semibold))
                .foregroundStyle(Theme.text3)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(Theme.font(Theme.Size.xl, .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.hairline2, lineWidth: 1)
        )
        .help(help)
    }
}

private struct StatMiniPill: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(Theme.font(Theme.Size.xs, .semibold))
                .foregroundStyle(Theme.text3)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(Theme.font(Theme.Size.body, .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Space.s3)
        .padding(.vertical, Theme.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.card)
        )
    }
}

private struct StatInlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
            Text(value)
                .font(Theme.font(Theme.Size.md, .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Label(title, systemImage: symbol)
                .font(Theme.font(Theme.Size.xs, .semibold))
                .foregroundStyle(Theme.text3)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(Theme.font(Theme.Size.lg, .bold))
                .monospacedDigit()
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.card)
        )
    }
}

/// A grouped-form action. Plain text on the row, same insets and hover as the toggles beside it.
private struct SettingsRowButton: View {
    var title: String
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title)
                .foregroundStyle(destructive ? Theme.bad : Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Settings (grouped Form, Apple HIG)

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case quizzes = "Quizzes"
    case experience = "App & appearance"
    case data = "Your data"
    var id: String { rawValue }
}

private struct SettingsPane: View {
    @ObservedObject var model: HomeModel
    var onResetStats: () -> Void = {}
    @State private var category = SettingsCategory.quizzes
    @State private var editingCustom = false
    @State private var confirmReset = false
    @State private var swipeAccess = TrackpadSwipeGuard.accessibilityTrusted

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                PageHeading(title: "Settings", subtitle: "Changes save automatically.")
                Picker("Settings category", selection: $category) {
                    ForEach(SettingsCategory.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(Theme.Space.s6)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            Form {
                if category == .quizzes {
                    Section {
                        Toggle("Every unlock", isOn: $model.quizOnUnlock)
                        Toggle("Also on wake from sleep", isOn: $model.quizOnWake)
                        Picker("Scheduled quiz", selection: $model.scheduleKind) {
                            ForEach(ScheduleKind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        if model.scheduleKind == .fixed {
                            ForEach($model.fixedSlots) { $slot in
                                HStack {
                                    DatePicker("Every day at", selection: $slot.date, displayedComponents: .hourAndMinute)
                                    Button {
                                        model.removeTime(slot.id)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(model.fixedSlots.count <= 1)
                                    .help("Remove this time")
                                    .accessibilityLabel("Remove scheduled quiz time")
                                }
                            }
                            SettingsRowButton(title: "Add a time") { model.addTime() }
                        }
                        if model.scheduleKind == .random {
                            DatePicker("From", selection: $model.randomStart, displayedComponents: .hourAndMinute)
                            DatePicker("To", selection: $model.randomEnd, displayedComponents: .hourAndMinute)
                            if let warning = model.windowWarning {
                                Text(warning).foregroundStyle(Theme.warn)
                            }
                            Toggle("Keep it a surprise", isOn: $model.surprise)
                        }
                        if model.scheduleKind != .off {
                            Text(model.statusText)
                                .foregroundStyle(Theme.text2)
                            Text("If your Mac is asleep or locked at that time, the quiz shows when you come back that day.")
                                .font(Theme.font(Theme.Size.xs))
                                .foregroundStyle(Theme.text3)
                        }
                    } header: {
                        Text("When to quiz")
                    }

                    Section {
                        Picker("Unlock questions", selection: $model.questionCount) {
                            ForEach(QuestionCount.allCases, id: \.self) { c in
                                Text(c.title).tag(c)
                            }
                        }
                        Toggle("Require 100% to unlock", isOn: $model.requirePerfect)
                        if model.requirePerfect {
                            Text("Missed countries are re-asked until all are right. After 10 minutes you can unlock anyway.")
                                .font(Theme.font(Theme.Size.xs))
                                .foregroundStyle(Theme.text3)
                        }
                        Picker("Ask about", selection: $model.subject) {
                            ForEach(QuizSubject.allCases, id: \.self) { s in
                                Text(s.title).tag(s)
                            }
                        }
                        Picker("Quiz type", selection: $model.quizType) {
                            ForEach(QuizType.allCases, id: \.self) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        Picker("Answer style", selection: $model.mode) {
                            ForEach(QuizMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .disabled(model.quizType == .click)
                    } header: {
                        Text("Unlock quiz")
                    } footer: {
                        Text(model.settingsUnlockSummary)
                            .font(Theme.font(Theme.Size.xs))
                    }

                    Section {
                        Toggle("Use custom set", isOn: $model.unlockUsesCustom)
                        if model.unlockUsesCustom {
                            CustomSetSummary {
                                editingCustom = true
                            }
                            .id(model.customRevision)
                        }
                        ForEach($model.regionFlags) { $flag in
                            Toggle(flag.region.title, isOn: $flag.on)
                        }
                    } header: {
                        Text("Regions for unlock quizzes")
                    } footer: {
                        Text(model.unlockUsesCustom && CustomSets.countries().count >= 2
                             ? "Unlock can use the custom set alone, or together with any continents you leave on."
                             : "At least one region stays on. Practice picks its own place.")
                    }
                    .sheet(isPresented: $editingCustom) {
                        CustomSetEditor {
                            model.customRevision += 1
                        }
                    }
                }

                if category == .experience {
                    Section {
                        Picker("Appearance", selection: $model.appearance) {
                            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } header: {
                        Text("Appearance")
                    }

                    Section {
                        Toggle("Answer sounds", isOn: $model.answerSounds)
                        Toggle("Friend request notifications", isOn: $model.friendRequestNotifications)
                        Toggle("Show prompt next to cursor", isOn: $model.cursorPrompt)
                        Toggle("Block trackpad swipes while locked", isOn: $model.blockTrackpadSwipes)
                        Text("Space, Mission Control, and App Exposé swipes pause during a lock quiz, then go back to how you had them.")
                            .font(Theme.font(Theme.Size.xs))
                            .foregroundStyle(Theme.text3)
                        if model.blockTrackpadSwipes && !swipeAccess {
                            Text("Allow Map Lock in Accessibility so it can stop the swipe on this Mac. The setting change alone does not.")
                                .font(Theme.font(Theme.Size.xs))
                                .foregroundStyle(Theme.text3)
                            SettingsRowButton(title: "Allow Accessibility Access…") {
                                TrackpadSwipeGuard.promptAccessibility()
                                swipeAccess = TrackpadSwipeGuard.accessibilityTrusted
                            }
                        }
                        Toggle("Open at login", isOn: $model.openAtLogin)
                            .disabled(!model.canUseLoginItem)
                        if let message = model.loginMessage {
                            Text(message).foregroundStyle(Theme.warn)
                        }
                        if model.needsApproval {
                            SettingsRowButton(title: "Open Login Items...") { model.openLoginItems() }
                        }
                        SettingsRowButton(title: "Hide Map Lock") { NSApp.terminate(nil) }
                    } header: {
                        Text("General")
                    } footer: {
                        Text("Hide keeps Map Lock running so quizzes still show. Force Quit is the only way to quit.")
                    }
                }

                if category == .data {
                    Section {
                        SettingsRowButton(title: "Reset stats…", destructive: true) { confirmReset = true }
                    } header: {
                        Text("Stats")
                    } footer: {
                        Text("Clears practice and unlock scores and personal bests. Races and friends are kept.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .toggleStyle(.switch)
        .onAppear { swipeAccess = TrackpadSwipeGuard.accessibilityTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            swipeAccess = TrackpadSwipeGuard.accessibilityTrusted
        }
        .confirmationDialog(
            "Reset stats?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset stats", role: .destructive) { onResetStats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes practice and unlock scores, the daily streak, the current unlock round, and speedrun personal bests on this Mac. A signed-in account loses that copy too, so it does not come back on the next sync. Race history and friends stay.")
        }
    }

}
