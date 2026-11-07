import SwiftUI

struct AccountPane: View {
    @ObservedObject var account: AccountModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s5) {
                Text("Account")
                    .font(Theme.font(Theme.Size.xl, .bold))
                    .kerning(-0.4)
                Text("Optional. Practice, quizzes, and speedrun keep working on this Mac with no account.")
                    .font(Theme.font(Theme.Size.body))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = account.message {
                    Text(message)
                        .font(Theme.font(Theme.Size.sm))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !account.isSignedIn {
                    signedOut
                } else if account.needsUsername {
                    usernameForm
                } else {
                    signedIn
                }
            }
            .padding(Theme.Space.s6)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { account.restoreIfNeeded() }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text("Sign in with Apple to add friends, sync stats between Macs, and race live. Map Lock stores your Apple user id and username, not your email.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                account.signIn()
            } label: {
                HStack(spacing: Theme.Space.s2) {
                    Image(systemName: "apple.logo")
                    Text("Sign in with Apple")
                }
                .frame(maxWidth: 280)
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 40, fullWidth: true))
            .disabled(account.busy)
        }
    }

    private var usernameForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Pick a username")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            TextField("letters, numbers, underscores", text: $account.usernameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button("Save username") { account.saveUsername() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 36))
                .disabled(account.busy)
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            HStack {
                Text(account.user?.username ?? "")
                    .font(Theme.font(Theme.Size.md, .semibold))
                Spacer()
                Button("Sync") { account.syncNow() }
                    .buttonStyle(AppButtonStyle(kind: .ghost))
                    .disabled(account.busy)
                Button("Sign out") { account.signOut() }
                    .buttonStyle(AppButtonStyle(kind: .ghost))
            }

            friendsSection
            leaderboardSection
            raceSection
            if account.friendView != nil {
                friendStats
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Friends")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            HStack {
                TextField("Username", text: $account.friendDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { account.addFriend() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
                    .disabled(account.busy)
            }
            friendList("Waiting for you", account.friends.incoming, incoming: true)
            friendList("Requests you sent", account.friends.outgoing, incoming: false)
            friendList("Friends", account.friends.friends, incoming: false)
        }
    }

    @ViewBuilder
    private func friendList(_ title: String, _ items: [FriendItem], incoming: Bool) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
            ForEach(items) { item in
                HStack {
                    Text(item.username ?? "Player")
                    Spacer()
                    if incoming {
                        Button("Accept") { account.accept(item) }.buttonStyle(AppButtonStyle(kind: .ghost))
                        Button("Decline") { account.decline(item) }.buttonStyle(AppButtonStyle(kind: .ghost))
                    } else if title == "Friends" {
                        Button("Stats") { account.openFriend(item) }.buttonStyle(AppButtonStyle(kind: .ghost))
                        Button("Remove") { account.remove(item) }.buttonStyle(AppButtonStyle(kind: .ghost))
                    } else {
                        Button("Cancel") { account.remove(item) }.buttonStyle(AppButtonStyle(kind: .ghost))
                    }
                }
            }
        }
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Friends speedrun board")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            Picker("Region", selection: $account.leaderboardRegion) {
                ForEach(PracticeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: account.leaderboardRegion) { _, _ in account.loadLeaderboard() }
            if account.leaderboard.isEmpty {
                Text("No times yet.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
            } else {
                ForEach(account.leaderboard) { row in
                    HStack {
                        Text(row.you ? "\(row.username) (you)" : row.username)
                        Spacer()
                        Text(row.time.map { SpeedrunClock.format($0) } ?? "-")
                            .monospacedDigit()
                            .foregroundStyle(Theme.text2)
                    }
                }
            }
        }
    }

    private var raceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("Live race")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            Text("Same countries, 3-2-1, first to finish wins. Your friend opens the link in Map Lock.")
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Race region", selection: $account.raceRegion) {
                ForEach(PracticeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            Button("Create race link") { account.createRace() }
                .buttonStyle(AppButtonStyle(kind: .primary, height: 36))
                .disabled(account.busy)
            if let race = account.lastRace {
                Text(race.webUrl)
                    .font(Theme.font(Theme.Size.xs))
                    .textSelection(.enabled)
                Text(race.appUrl)
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
                    .textSelection(.enabled)
            }
            HStack {
                TextField("Race code", text: $account.joinCode)
                    .textFieldStyle(.roundedBorder)
                Button("Join") { account.joinDraft() }
                    .buttonStyle(AppButtonStyle(kind: .ghost))
                    .disabled(account.busy)
            }
        }
    }

    private var friendStats: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text("\(account.friendView?.username ?? "Friend") · read only")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            Text("Accuracy \(account.friendSnapshot.overallAccuracyText) · questions \(account.friendSnapshot.totalQuestionsText)")
                .font(Theme.font(Theme.Size.sm))
            ForEach(account.friendSnapshot.speedrunBests) { row in
                HStack {
                    Text(row.scopeTitle)
                    Spacer()
                    Text(row.timeText).monospacedDigit().foregroundStyle(Theme.text2)
                }
            }
            if account.friendSnapshot.history.isEmpty {
                Text("No synced quizzes yet.")
                    .font(Theme.font(Theme.Size.xs))
                    .foregroundStyle(Theme.text3)
            } else {
                ForEach(Array(account.friendSnapshot.history.prefix(8))) { row in
                    HStack {
                        Text("\(row.kindTitle) · \(row.scopeTitle)")
                        Spacer()
                        Text(row.scoreText).monospacedDigit()
                    }
                    .font(Theme.font(Theme.Size.xs))
                }
            }
        }
    }
}
