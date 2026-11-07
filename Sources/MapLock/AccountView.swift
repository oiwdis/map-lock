import AppKit
import SwiftUI

struct AccountPane: View {
    @ObservedObject var account: AccountModel
    @ObservedObject var home: HomeModel
    @State private var passwordBusy = false
    @FocusState private var focus: SignInField?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Theme.Space.s4) {
                    if !account.isSignedIn {
                        signedOut
                            .frame(maxWidth: 420)
                    } else if account.needsUsername {
                        usernameForm
                            .frame(maxWidth: 420)
                    } else {
                        signedIn
                    }
                }
                .padding(.horizontal, Theme.Space.s6)
                .padding(.vertical, Theme.Space.s5)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .frame(minHeight: account.isSignedIn && !account.needsUsername ? CGFloat(0) : max(0, geo.size.height - Theme.Space.s6),
                       alignment: .center)
            }
        }
        .onAppear {
            account.restoreIfNeeded()
            account.seedRaceOptions(subject: home.practiceSubject, style: home.practiceAnswerStyle)
            account.refreshClipboardOffer()
            if !account.isSignedIn { focus = .username }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn { focus = .username }
        }
        .onChange(of: account.busy) { _, busy in
            if !busy { passwordBusy = false }
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            VStack(spacing: Theme.Space.s2) {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text("Map Lock Account")
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                Text("Race a friend, or keep your stats on every Mac.")
                    .font(Theme.font(Theme.Size.body))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            AccountField(title: "Username") {
                TextField("Username", text: $account.loginUsername)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
            }
            PasswordField(title: "Password", text: $account.loginPassword, focus: $focus, field: .password) {
                if account.creatingAccount {
                    focus = .confirm
                } else {
                    submitPassword()
                }
            }
            if account.creatingAccount {
                PasswordField(title: "Confirm password", text: $account.confirmPassword, focus: $focus, field: .confirm, next: submitPassword)
                Text("Use 8 or more characters.")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
            }

            if let error = formError {
                Text(explain(error))
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submitPassword) {
                HStack(spacing: Theme.Space.s2) {
                    if passwordBusy && account.busy {
                        ProgressView().controlSize(.small).tint(Color.white)
                    }
                    Text(account.creatingAccount ? "Create account" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
            .disabled(account.busy)

            HitButton {
                account.setCreatingAccount(!account.creatingAccount)
                focus = .username
            } label: {
                Text(account.creatingAccount ? "Have an account? Sign in" : "Need an account? Create one")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }

            HStack(spacing: Theme.Space.s3) {
                Rectangle().fill(Theme.hairline2).frame(height: 1)
                Text("or")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text3)
                Rectangle().fill(Theme.hairline2).frame(height: 1)
            }

            HitButton(enabled: !account.busy) {
                account.signIn()
            } label: {
                AppleSignInLabel()
            }
            .opacity(account.busy ? 0.6 : 1)

            Text("Optional. Everything works without an account.")
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.s6)
        .accountCardChrome()
    }

    private var formError: String? {
        guard let message = account.message, !message.isEmpty else { return nil }
        return message
    }

    private func explain(_ message: String) -> String {
        switch message {
        case "Usernames are 3 to 20 characters":
            return "Usernames are 3 to 20 characters. Try a different length."
        case "Use letters, numbers, and underscores only":
            return "Use letters, numbers, and underscores only."
        case "That username is reserved":
            return "That username is reserved. Pick another."
        case "Pick a different username":
            return "Pick a different username."
        default:
            return message
        }
    }

    private func submitPassword() {
        if account.submitPasswordAccount() {
            passwordBusy = true
        } else {
            focus = .username
        }
    }

    // MARK: Username after Apple

    private var usernameForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("Pick a username")
                .font(Theme.font(Theme.Size.lg, .bold))
                .foregroundStyle(Theme.text)
            Text("Friends will see this name. Use 3 to 20 letters, numbers, or underscores.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Username", text: $account.usernameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { account.saveUsername() }
            if let message = account.message, message != "Pick a username." {
                Text(explain(message))
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.bad)
            }
            Button("Save username") { account.saveUsername() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
                .disabled(account.busy)
        }
        .padding(Theme.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accountCardChrome()
    }

    // MARK: Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            profileHeader
            if account.justJoined {
                welcomeCard
            }
            if !account.friends.incoming.isEmpty && account.page != .friends {
                HitButton { account.page = .friends } label: {
                    Text("You have a friend request")
                        .font(Theme.font(Theme.Size.sm, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 28)
                }
            }
            AccountSegment(
                selection: $account.page,
                choices: AccountPage.allCases.map { SegmentChoice(value: $0, title: $0.title) }
            )
            if let notice = bannerNotice {
                Text(notice)
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(noticeIsGood(notice) ? Theme.good : Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch account.page {
            case .race: racePage
            case .board: boardPage
            case .friends: friendsPage
            }
        }
    }

    private var bannerNotice: String? {
        guard let message = account.message, !message.isEmpty else { return nil }
        if account.page == .friends && isFriendNotice(message) { return nil }
        if account.page == .race, message.lowercased().contains("copied") { return nil }
        return message
    }

    private func isFriendNotice(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("request") || lower.contains("username") || lower.contains("friend") || lower.contains("that's you")
    }

    private func noticeIsGood(_ text: String) -> Bool {
        text.lowercased().contains("copied") || text.lowercased().contains("request sent")
    }

    private var profileHeader: some View {
        HStack(spacing: Theme.Space.s3) {
            AccountAvatar(name: account.user?.username ?? "", size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.user?.username ?? "")
                    .font(Theme.font(Theme.Size.md, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(account.signInKind?.caption ?? "Signed in")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                syncedLine
            }
            Spacer(minLength: Theme.Space.s2)
            HitButton(enabled: !account.busy) {
                account.syncNow()
            } label: {
                Group {
                    if account.syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.fill2))
            }
            .help("Sync now")
            .opacity(account.busy ? 0.5 : 1)
            Menu {
                Button("Sign Out") { account.signOut() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.fill2))
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Account")
        }
    }

    private var syncedLine: some View {
        Group {
            if let date = account.lastSyncedAt {
                TimelineView(.periodic(from: date, by: 30)) { _ in
                    Text(syncedPhrase(date))
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                Text("Not synced yet")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private func syncedPhrase(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 45 { return "Synced just now" }
        let minutes = max(1, seconds / 60)
        if minutes < 60 { return "Synced \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Synced \(hours) hr ago" }
        return "Synced \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("You're in.")
                .font(Theme.font(Theme.Size.md, .semibold))
                .foregroundStyle(Theme.text)
            Text("Add a friend, or race someone.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
            HStack(spacing: Theme.Space.s2) {
                Button("Add a friend") {
                    account.page = .friends
                    account.dismissWelcome()
                }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
                Button("Race someone") {
                    account.page = .race
                    account.dismissWelcome()
                }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
            }
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accountCardChrome()
    }

    // MARK: Race

    private var racePage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("Race a friend")
                .font(Theme.font(Theme.Size.lg, .bold))
                .foregroundStyle(Theme.text)
            Text("Pick a place, then send the link.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)

            AccountField(title: "Where") {
                Picker("Where", selection: $account.raceRegion) {
                    ForEach(PracticeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            DisclosureGroup("Options") {
                VStack(alignment: .leading, spacing: Theme.Space.s3) {
                    Text("Uses your Practice settings until you change them.")
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                    AccountSegment(
                        selection: $account.raceSubject,
                        choices: QuizSubject.allCases.map { SegmentChoice(value: $0, title: $0.practiceTitle) }
                    )
                    Picker("How to answer", selection: $account.raceStyle) {
                        ForEach(PracticeAnswerStyle.allCases) { style in
                            Text(style.title(for: account.raceSubject)).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.top, Theme.Space.s2)
            }
            .font(Theme.font(Theme.Size.sm, .semibold))
            .foregroundStyle(Theme.text2)

            Button { account.createRace() } label: {
                Text("Create race")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
            .disabled(account.busy)

            if let race = account.lastRace {
                raceLobby(race)
            }

            Divider().overlay(Theme.hairline2)

            Text("Have a code?")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text)
            TextField("Paste it here", text: $account.joinCode)
                .textFieldStyle(.roundedBorder)
                .onSubmit { account.joinDraft() }
                .onChange(of: account.joinCode) { _, value in
                    guard let code = RaceLink.code(in: value), code != value else { return }
                    account.joinCode = code
                }
            if let code = account.clipboardCode {
                HitButton {
                    account.joinClipboard()
                } label: {
                    Text("Join race from clipboard?")
                        .font(Theme.font(Theme.Size.sm, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 28)
                }
                .help(code)
            }
            Button("Join") { account.joinDraft() }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                .disabled(account.busy || account.joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accountCardChrome()
        .onAppear { account.refreshClipboardOffer() }
    }

    private func raceLobby(_ race: RaceTicket) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Waiting for your friend")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text)
            Text(race.code)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Text(race.webUrl)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.s2) {
                Button("Copy") { account.copyLastRaceLink() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
                RaceShareButton(text: race.webUrl)
                    .frame(width: 96, height: 32)
            }
            if let message = account.message, message.contains("copied") || message.contains("Copied") {
                Text(message)
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.good)
            }
        }
        .padding(Theme.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.fill)
        )
    }

    // MARK: Leaderboard

    private var boardPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("How you compare")
                .font(Theme.font(Theme.Size.lg, .bold))
                .foregroundStyle(Theme.text)
            AccountSegment(
                selection: $account.leaderboardSubject,
                choices: QuizSubject.allCases.map { SegmentChoice(value: $0, title: $0.practiceTitle) }
            )
            .onChange(of: account.leaderboardSubject) { _, _ in account.loadLeaderboard() }
            HStack(spacing: Theme.Space.s3) {
                Picker("Method", selection: $account.leaderboardStyle) {
                    ForEach(PracticeAnswerStyle.allCases) { style in
                        Text(style.title(for: account.leaderboardSubject)).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: account.leaderboardStyle) { _, _ in account.loadLeaderboard() }
                Picker("Region", selection: $account.leaderboardRegion) {
                    ForEach(PracticeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: account.leaderboardRegion) { _, _ in account.loadLeaderboard() }
            }

            yourRank

            if !hasTimes {
                VStack(spacing: Theme.Space.s3) {
                    Text("Finish a speedrun to post a time")
                        .font(Theme.font(Theme.Size.sm))
                        .foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center)
                    Button("Start a speedrun") { account.beginSpeedrun() }
                        .buttonStyle(AppButtonStyle(kind: .primary, height: 36))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.s3)
            } else {
                VStack(spacing: Theme.Space.s1) {
                    ForEach(Array(account.leaderboard.enumerated()), id: \.element.id) { index, row in
                        boardRow(rank: index + 1, row: row)
                    }
                }
            }
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accountCardChrome()
    }

    private var hasTimes: Bool {
        account.leaderboard.contains { $0.time != nil }
    }

    private var yourRank: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            if let row = account.leaderboard.first(where: { $0.you }), let time = row.time,
               let rank = account.leaderboard.firstIndex(where: { $0.you }).map({ $0 + 1 }) {
                Text("Your best is \(SpeedrunClock.format(time)). You are \(place(rank)).")
                    .font(Theme.font(Theme.Size.body, .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("You have no time yet.")
                    .font(Theme.font(Theme.Size.body, .semibold))
                    .foregroundStyle(Theme.text)
                Button("Start a speedrun") { account.beginSpeedrun() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
            }
        }
    }

    private func boardRow(rank: Int, row: LeaderboardRow) -> some View {
        HStack(spacing: Theme.Space.s3) {
            RankBadge(rank: rank, timed: row.time != nil)
            Text(row.you ? "\(row.username) (you)" : row.username)
                .font(Theme.font(Theme.Size.body, row.you ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s2)
            Text(row.time.map { SpeedrunClock.format($0) } ?? "No time yet")
                .font(Theme.font(Theme.Size.sm, .medium))
                .monospacedDigit()
                .foregroundStyle(row.time == nil ? Theme.text3 : Theme.text)
        }
        .padding(.horizontal, Theme.Space.s2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(row.you ? Theme.accentFill.opacity(0.14) : Color.clear)
        )
    }

    private func place(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    // MARK: Friends

    private var friendsPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("Friends")
                .font(Theme.font(Theme.Size.lg, .bold))
                .foregroundStyle(Theme.text)
            Text("They have to accept before you can race.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)

            HStack(spacing: Theme.Space.s2) {
                TextField("Username", text: $account.friendDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { account.addFriend() }
                HitButton(enabled: !account.busy) {
                    account.addFriend()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.accentFill))
                }
                .help("Add friend")
                .opacity(account.busy ? 0.5 : 1)
            }

            if let message = account.message, isFriendNotice(message) {
                Text(message)
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(noticeIsGood(message) ? Theme.good : Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !account.friends.incoming.isEmpty {
                Text("Wants to be friends")
                    .font(Theme.font(Theme.Size.xs, .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(account.friends.incoming) { item in
                    HStack(spacing: Theme.Space.s3) {
                        AccountAvatar(name: item.username ?? "?", size: 32)
                        Text(item.username ?? "Player")
                            .font(Theme.font(Theme.Size.body, .medium))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Button("Accept") { account.accept(item) }.buttonStyle(QuietButtonStyle())
                        Button("Decline") { account.decline(item) }.buttonStyle(QuietButtonStyle())
                    }
                }
            }

            if !account.friends.outgoing.isEmpty {
                Text("Waiting for them")
                    .font(Theme.font(Theme.Size.xs, .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(account.friends.outgoing) { item in
                    HStack(spacing: Theme.Space.s3) {
                        AccountAvatar(name: item.username ?? "?", size: 32)
                        Text(item.username ?? "Player")
                            .font(Theme.font(Theme.Size.body))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text("Asked")
                            .font(Theme.font(Theme.Size.xs))
                            .foregroundStyle(Theme.text3)
                    }
                    .contextMenu {
                        Button("Cancel request") { account.remove(item) }
                    }
                }
            }

            if account.friends.friends.isEmpty && account.friends.incoming.isEmpty && account.friends.outgoing.isEmpty {
                Text("Add a friend by username to compare times.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                    .padding(.vertical, Theme.Space.s2)
            } else if !account.friends.friends.isEmpty {
                Text("Friends")
                    .font(Theme.font(Theme.Size.xs, .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(account.friends.friends) { item in
                    HStack(spacing: Theme.Space.s3) {
                        AccountAvatar(name: item.username ?? "?", size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.username ?? "Player")
                                .font(Theme.font(Theme.Size.body, .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if let time = friendTime(item) {
                                Text(time)
                                    .font(Theme.font(Theme.Size.xs))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.text3)
                            }
                        }
                        Spacer()
                        Button("Race") { account.createRace(telling: item.username) }
                            .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
                            .disabled(account.busy)
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { account.remove(item) }
                    }
                }
            }
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accountCardChrome()
    }

    private func friendTime(_ item: FriendItem) -> String? {
        guard let name = item.username?.lowercased() else { return nil }
        guard let row = account.leaderboard.first(where: { $0.username.lowercased() == name }),
              let time = row.time else { return nil }
        return SpeedrunClock.format(time)
    }
}

private enum SignInField: Hashable {
    case username, password, confirm
}

private struct SegmentChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// System segmented control. The whole segment is the hit target, including the
/// click that leaves a text field, and the selected label stays white.
private struct AccountSegment<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [SegmentChoice<Value>]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(choices) { choice in
                Text(choice.title).tag(choice.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
    }
}

private struct AccountField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            Text(title)
                .font(Theme.font(Theme.Size.xs, .semibold))
                .foregroundStyle(Theme.text3)
            content
        }
    }
}

private struct PasswordField: View {
    let title: String
    @Binding var text: String
    var focus: FocusState<SignInField?>.Binding
    var field: SignInField
    var next: () -> Void
    @State private var shown = false

    var body: some View {
        AccountField(title: title) {
            HStack(spacing: Theme.Space.s2) {
                Group {
                    if shown {
                        TextField(title, text: $text)
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: field)
                .onSubmit(next)
                HitButton {
                    shown.toggle()
                } label: {
                    Image(systemName: shown ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.text3)
                        .frame(width: 28, height: 28)
                }
                .help(shown ? "Hide password" : "Show password")
            }
        }
    }
}

private struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(tint))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split { $0 == "_" || $0 == " " || $0 == "-" }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            let first = parts[0].first.map(String.init) ?? ""
            let second = parts[1].first.map(String.init) ?? ""
            return (first + second).uppercased()
        }
        let letters = name.filter(\.isLetter)
        let raw = String(letters.prefix(2)).uppercased()
        return raw.isEmpty ? "?" : raw
    }

    private var tint: Color {
        let palette: [UInt32] = [0x0062CC, 0x17702F, 0x6D28D9, 0xB45309, 0x0F766E, 0xBE123C]
        var hash = 0
        for byte in name.lowercased().utf8 {
            hash = (hash &* 31 &+ Int(byte)) % palette.count
        }
        let index = hash < 0 ? -hash : hash
        return Color(hex: palette[index % palette.count])
    }
}

private struct RankBadge: View {
    let rank: Int
    let timed: Bool

    var body: some View {
        Text("\(rank)")
            .font(Theme.font(Theme.Size.xs, .bold))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(Circle().fill(fill))
    }

    private var fill: Color {
        guard timed else { return Theme.fill2 }
        switch rank {
        case 1: return Color(hex: 0xB8860B)
        case 2: return Color(hex: 0x8E8E93)
        case 3: return Color(hex: 0xA15C38)
        default: return Theme.fill2
        }
    }

    private var foreground: Color {
        if timed && (rank == 1 || rank == 3) { return Color.white }
        if timed && rank == 2 { return Color(hex: 0x1C1C1E) }
        return Theme.text
    }
}

private struct AppleSignInLabel: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 8) {
            Image(systemName: "apple.logo")
                .font(.system(size: 16, weight: .medium))
            Text("Sign in with Apple")
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(dark ? Color.black : Color.white)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dark ? Color.white : Color.black))
    }
}

private extension View {
    func accountCardChrome() -> some View {
        background(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline2, lineWidth: 1))
    }
}
