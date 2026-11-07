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
    case stats
    case account
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .practice: return "Practice"
        case .stats: return "Stats"
        case .account: return "Account"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .practice: return "map"
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
            if on.isEmpty {
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

    @Published var questionCount: QuestionCount = .five {
        didSet { if !loading { settings.questionCount = questionCount; onChange() } }
    }

    @Published var requirePerfect = false {
        didSet { if !loading { settings.requirePerfect = requirePerfect; onChange() } }
    }

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
        questionCount = settings.questionCount
        requirePerfect = settings.requirePerfect
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
        onPractice(practiceChoice.scope, practiceLength)
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

@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    let model: HomeModel
    let account: AccountModel
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
            w.contentView = NSHostingView(rootView: HomeView(model: model, account: account))
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

    /// About 760x560, or smaller if the screen is tight, centered in the visible frame.
    private static func fittedFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(760, max(680, screen.width * 0.72))
        let height = min(560, max(460, screen.height * 0.72))
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

    var body: some View {
        NavigationSplitView {
            List(selection: $model.homeTab) {
                Section {
                    ForEach(HomeTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .overlay(HitTarget { model.homeTab = tab })
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            // Keep system label colors so the selected row gets white (or vibrancy) on the blue highlight.
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .foregroundStyle(Theme.text)
        }
        .navigationSplitViewStyle(.balanced)
        // Do not set foregroundStyle on the split view: it paints sidebar labels dark on the selection fill.
        // No preferredColorScheme: NSApp.appearance drives Light / Dark / Match system.
        .frame(minWidth: 680, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.onQuizNow()
                } label: {
                    Label("Quiz me now", systemImage: "play.fill")
                }
                .help("Start an unlock quiz with Unlock quiz settings")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.homeTab {
        case .practice:
            PracticePane(model: model)
        case .stats:
            StatsPane(model: model)
        case .account:
            AccountPane(account: account, home: model)
        case .settings:
            SettingsPane(model: model)
        }
    }
}

// MARK: Practice

private struct PracticePane: View {
    @ObservedObject var model: HomeModel

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: Theme.Space.s2)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s5) {
                header
                modeSection
                whereSection
                if !model.practiceSpeedrun {
                    lengthSection
                }
                Button {
                    model.startPracticeNow()
                } label: {
                    HStack(spacing: Theme.Space.s2) {
                        Image(systemName: model.practiceSpeedrun ? "timer" : "play.fill")
                        Text(model.practiceSpeedrun ? "Start speedrun" : "Start practice")
                    }
                    .frame(maxWidth: 280)
                }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
                .padding(.top, Theme.Space.s1)

                Text("Practice never locks the screen. Quiz me now (toolbar) uses Unlock quiz in Settings.")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The crowd already has a path. Yours is the one you cut yourself.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                    .padding(.top, Theme.Space.s3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Practice")
                .font(Theme.font(Theme.Size.xl, .bold))
                .kerning(-0.4)
            Text("Pick what to practice, how to answer, then a place.")
                .font(Theme.font(Theme.Size.body))
                .foregroundStyle(Theme.text2)
            HStack(spacing: Theme.Space.s2) {
                Pill {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.warn)
                    Text(model.streak == 1 ? "1 day streak" : "\(model.streak) day streak")
                }
                Pill {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.text2)
                    Text("Round \(model.roundText)").monospacedDigit()
                }
            }
            .padding(.top, Theme.Space.s1)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("What to practice")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            HStack(spacing: Theme.Space.s2) {
                ForEach(QuizSubject.allCases) { subject in
                    PracticeModeChip(
                        title: subject.practiceTitle,
                        symbol: subject.practiceSymbol,
                        selected: model.practiceSubject == subject
                    ) {
                        model.selectPracticeSubject(subject)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                Text("How to answer")
                    .font(Theme.font(Theme.Size.sm, .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(PracticeAnswerStyle.allCases) { style in
                    PracticeAnswerRow(
                        title: style.title(for: model.practiceSubject),
                        selected: model.practiceAnswerStyle == style
                    ) {
                        model.selectPracticeAnswerStyle(style)
                    }
                }
                Text(model.practiceHelpText)
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.s1)
                Divider()
                    .padding(.top, Theme.Space.s2)
                Toggle("Speedrun", isOn: $model.practiceSpeedrun)
                    .toggleStyle(.switch)
                    .font(Theme.font(Theme.Size.body, .medium))
                Text("Timer on, no pause between questions.")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline2, lineWidth: 1)
            )
        }
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Where")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            LazyVGrid(columns: columns, spacing: Theme.Space.s2) {
                ForEach(PracticeChoice.allCases) { choice in
                    PracticePlaceCard(
                        title: choice.title,
                        symbol: symbol(for: choice),
                        selected: model.practiceChoice == choice
                    ) {
                        model.practiceChoice = choice
                    }
                }
            }
            Text(model.practicePoolHint)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
        }
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Questions")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            Picker("Questions", selection: $model.practiceLength) {
                ForEach(PracticeLength.allCases) { length in
                    Text(length.title).tag(length)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
        }
    }

    private func symbol(for choice: PracticeChoice) -> String {
        switch choice {
        case .africa: return "globe.europe.africa"
        case .asia: return "globe.asia.australia"
        case .europe: return "globe.europe.africa"
        case .northAmerica, .southAmerica: return "globe.americas"
        case .world: return "globe"
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
            .padding(.vertical, Theme.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.text2)
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Space.s3)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.accentFill : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accentFill : Theme.hairline2, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Stats

private struct StatsPane: View {
    @ObservedObject var model: HomeModel

    private var snap: StatsSnapshot { model.statsSnapshot }

    var body: some View {
        Form {
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
                Text("Overview")
            } footer: {
                Text("Practice and unlock quizzes both count here. Saved on this Mac only.")
            }

            kindSection(title: "Practice", summary: snap.practice, empty: "Finish a practice test to see numbers here.")
            kindSection(title: "Unlock", summary: snap.unlock, empty: "Finish an unlock quiz to see numbers here.")

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
                Text("Fastest time for each place. A miss still counts in the time. Saved on this Mac only.")
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
                    Text("No misses yet. Keep practicing.")
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
    }

    @ViewBuilder
    private func kindSection(title: String, summary: StatsKindSummary, empty: String) -> some View {
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

                if !summary.byScope.isEmpty {
                    Text("By place")
                        .font(Theme.font(Theme.Size.xs, .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(.top, Theme.Space.s1)
                    ForEach(summary.byScope) { row in
                        breakdownRow(row)
                    }
                }

                if !summary.bySubject.isEmpty {
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
                .font(Theme.font(Theme.Size.lg, .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
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

// MARK: Settings (grouped Form, Apple HIG)

private struct SettingsPane: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        Form {
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
                        }
                    }
                    Button("Add a time") { model.addTime() }
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
                ForEach($model.regionFlags) { $flag in
                    Toggle(flag.region.title, isOn: $flag.on)
                }
            } header: {
                Text("Regions for unlock quizzes")
            } footer: {
                Text("At least one region stays on. Practice picks its own place.")
            }

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
                Toggle("Open at login", isOn: $model.openAtLogin)
                    .disabled(!model.canUseLoginItem)
                if let message = model.loginMessage {
                    Text(message).foregroundStyle(Theme.warn)
                }
                if model.needsApproval {
                    Button("Open Login Items...") { model.openLoginItems() }
                }
                Button("Hide Map Lock") { NSApp.terminate(nil) }
            } header: {
                Text("General")
            } footer: {
                Text("Hide keeps Map Lock running so quizzes still show. Force Quit is the only way to quit.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

}
