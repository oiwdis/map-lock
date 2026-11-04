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

    @Published var mode: QuizMode = .mixed {
        didSet { if !loading { settings.mode = mode; onChange() } }
    }

    @Published var regionFlags: [RegionFlag] = [] {
        didSet {
            guard !loading else { return }
            let on = Set(regionFlags.filter { $0.on }.map { $0.region })
            if on.isEmpty {
                // Keep at least one region on.
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
        let on = settings.regions
        regionFlags = Region.allCases.map { RegionFlag(region: $0, on: on.contains($0)) }
        quizOnUnlock = settings.quizOnUnlock
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
        roundText = "Round progress: \(p.shown) of \(p.total)"
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
        // Next free hour after the last time, or 4:00 PM.
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
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Map Lock"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
            w.minSize = NSSize(width: 420, height: 520)
            w.contentView = NSHostingView(rootView: HomeView(model: model))
            w.setContentSize(NSSize(width: 460, height: 760))
            w.center()
            _ = w.setFrameAutosaveName("MapLockHome")
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: View

struct HomeView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: Theme.Space.s4) {
                    header
                    styleCard
                    regionsCard
                    scheduleCard
                    loginCard
                    HStack {
                        Spacer()
                        Button("Quit Map Lock") { NSApp.terminate(nil) }
                            .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                    }
                }
                .padding(.horizontal, Theme.Space.s6)
                .padding(.top, Theme.Space.s10)
                .padding(.bottom, Theme.Space.s6)
            }
        }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 420, minHeight: 520)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s3) {
            AppBadge(size: 72)
            Text("Map Lock")
                .font(Theme.font(Theme.Size.xl, .bold))
                .kerning(-0.5)
            Text("Name a few countries to unlock your Mac.")
                .font(Theme.font(Theme.Size.body))
                .foregroundStyle(Theme.text2)
            HStack(spacing: Theme.Space.s2) {
                Pill {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.warn)
                    Text(model.streak == 1 ? "1 day streak" : "\(model.streak) day streak")
                }
                Pill { Text(model.roundText).monospacedDigit() }
            }
            Button {
                model.onQuizNow()
            } label: {
                HStack(spacing: Theme.Space.s2) {
                    Image(systemName: "play.fill")
                    Text("Quiz me now")
                }
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 44, fullWidth: true))
            .padding(.top, Theme.Space.s2)
        }
        .padding(.bottom, Theme.Space.s2)
    }

    private var styleCard: some View {
        Card(title: "Answer style") {
            Picker("Answer style", selection: $model.mode) {
                ForEach(QuizMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var regionsCard: some View {
        Card(title: "Regions") {
            VStack(spacing: Theme.Space.s1) {
                ForEach($model.regionFlags) { $flag in
                    SwitchRow(title: flag.region.title, isOn: $flag.on)
                }
            }
        }
    }

    private var scheduleCard: some View {
        Card(title: "When to quiz") {
            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                SwitchRow(title: "Every unlock", isOn: $model.quizOnUnlock)

                Divider().overlay(Theme.hairline)

                HStack {
                    Text("Scheduled quiz")
                        .font(Theme.font(Theme.Size.body))
                    Spacer()
                    Picker("Scheduled quiz", selection: $model.scheduleKind) {
                        ForEach(ScheduleKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                if model.scheduleKind == .fixed {
                    ForEach($model.fixedSlots) { $slot in
                        HStack {
                            Text("Every day at")
                                .font(Theme.font(Theme.Size.body))
                                .foregroundStyle(Theme.text2)
                            Spacer()
                            DatePicker("Time", selection: $slot.date, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                            Button {
                                model.removeTime(slot.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(model.fixedSlots.count > 1 ? Theme.text2 : Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.fixedSlots.count <= 1)
                            .help("Remove this time")
                        }
                    }
                    Button {
                        model.addTime()
                    } label: {
                        HStack(spacing: Theme.Space.s1) {
                            Image(systemName: "plus")
                            Text("Add a time")
                        }
                    }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                }

                if model.scheduleKind == .random {
                    HStack {
                        Text("Between")
                            .font(Theme.font(Theme.Size.body))
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        DatePicker("From", selection: $model.randomStart, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                        Text("and")
                            .font(Theme.font(Theme.Size.body))
                            .foregroundStyle(Theme.text2)
                        DatePicker("To", selection: $model.randomEnd, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    if let warning = model.windowWarning {
                        Text(warning)
                            .font(Theme.font(Theme.Size.xs))
                            .foregroundStyle(Theme.warn)
                    }
                    SwitchRow(title: "Keep it a surprise", isOn: $model.surprise)
                }

                if model.scheduleKind != .off {
                    HStack(spacing: Theme.Space.s2) {
                        Image(systemName: "clock")
                            .foregroundStyle(Theme.accent)
                        Text(model.statusText)
                            .font(Theme.font(Theme.Size.sm, .medium))
                            .foregroundStyle(Theme.text2)
                    }
                    Text("If your Mac is asleep or locked at that time, the quiz shows when you come back that day.")
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var loginCard: some View {
        Card(title: "Startup") {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                SwitchRow(title: "Open at login", isOn: $model.openAtLogin)
                    .disabled(!model.canUseLoginItem)
                if let message = model.loginMessage {
                    Text(message)
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.needsApproval {
                    Button("Open Login Items") { model.openLoginItems() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                }
            }
        }
    }
}

/// Glass card with a small section label.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            SectionLabel(title)
            content
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: Theme.Radius.lg, shadow: false)
    }
}

/// A label with a switch on the right.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(Theme.font(Theme.Size.body))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(Theme.good)
        .frame(minHeight: 28)
    }
}
