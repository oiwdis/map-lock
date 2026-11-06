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
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .practice: return "Practice"
        case .stats: return "Stats"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .practice: return "map"
        case .stats: return "chart.bar"
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
    @Published private(set) var mostMissedLines: [(name: String, wrong: Int)] = []

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
        questionCount = settings.questionCount
        requirePerfect = settings.requirePerfect
        subject = settings.subject
        practiceSubject = settings.practiceSubject
        practiceAnswerStyle = settings.practiceStyle(for: settings.practiceSubject)
        practiceLength = settings.practiceLength
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
        let pct = stats.bestPercent
        bestPercentText = pct > 0 ? String(format: "%.0f%%", pct * 100) : "-"
        if let t = stats.bestTimeSeconds {
            let sec = Int(t.rounded())
            bestTimeText = "\(sec / 60):" + String(format: "%02d", sec % 60)
        } else {
            bestTimeText = "-"
        }
        let missed = stats.mostMissed(limit: 8)
        mostMissedLines = missed.map { (name: $0.name, wrong: $0.wrong) }
        mostMissedText = missed.isEmpty ? "-" : missed.prefix(3).map(\.name).joined(separator: ", ")
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

    /// Switching practice subject loads that subject's saved answer style.
    func selectPracticeSubject(_ subject: QuizSubject) {
        guard practiceSubject != subject else { return }
        loading = true
        practiceSubject = subject
        practiceAnswerStyle = settings.practiceStyle(for: subject)
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
        switch practiceChoice.scope {
        case .world: return "Every included country (no Oceania)."
        case .region(let r): return "Only \(r.title): that continent map and countries only."
        }
    }

    var canUseLoginItem: Bool { LoginItem.isAppBundle }
    var needsApproval: Bool { LoginItem.needsApproval }

    func openLoginItems() { LoginItem.openLoginItemsSettings() }
}

// MARK: Window

@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    let model: HomeModel
    private var window: NSWindow?

    init(model: HomeModel) {
        self.model = model
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
            w.contentView = NSHostingView(rootView: HomeView(model: model))
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

    var body: some View {
        NavigationSplitView {
            List(selection: $model.homeTab) {
                Section {
                    ForEach(HomeTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(Theme.text)
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
                lengthSection
                Button {
                    model.startPracticeNow()
                } label: {
                    HStack(spacing: Theme.Space.s2) {
                        Image(systemName: "play.fill")
                        Text("Start practice")
                    }
                    .frame(maxWidth: 280)
                }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
                .padding(.top, Theme.Space.s1)

                Text("Practice never locks the screen. Quiz me now (toolbar) uses Unlock quiz in Settings.")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
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
        Button(action: action) {
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .padding(.horizontal, Theme.Space.s3)
            .padding(.vertical, Theme.Space.s2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.12) : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline2, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PracticeAnswerRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .padding(.vertical, Theme.Space.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PracticePlaceCard: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.text2)
                Text(title)
                    .font(Theme.font(Theme.Size.body, selected ? .semibold : .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Space.s3)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.12) : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline2, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Stats

private struct StatsPane: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s5) {
                Text("Stats")
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .kerning(-0.4)
                Text("Saved on this Mac only.")
                    .font(Theme.font(Theme.Size.body))
                    .foregroundStyle(Theme.text2)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: Theme.Space.s3) {
                    StatTile(title: "Best score", value: model.bestPercentText, symbol: "star.fill")
                    StatTile(title: "Best time", value: model.bestTimeText, symbol: "timer")
                    StatTile(title: "Streak",
                             value: model.streak == 1 ? "1 day" : "\(model.streak) days",
                             symbol: "flame.fill")
                }

                VStack(alignment: .leading, spacing: Theme.Space.s2) {
                    Text("Most missed")
                        .font(Theme.font(Theme.Size.sm, .semibold))
                        .foregroundStyle(Theme.text3)
                    if model.mostMissedLines.isEmpty {
                        Text("No misses yet.")
                            .font(Theme.font(Theme.Size.body))
                            .foregroundStyle(Theme.text2)
                    } else {
                        ForEach(model.mostMissedLines, id: \.name) { row in
                            HStack {
                                Text(row.name)
                                    .font(Theme.font(Theme.Size.body))
                                Spacer()
                                Text("\(row.wrong)")
                                    .font(Theme.font(Theme.Size.body, .medium))
                                    .foregroundStyle(Theme.text2)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, Theme.Space.s1)
                        }
                    }
                }
                .padding(Theme.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Theme.card)
                )

                Pill {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.text2)
                    Text("Round \(model.roundText)").monospacedDigit()
                }
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
