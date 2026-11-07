import AppKit
import AuthenticationServices
import SwiftUI

/// Optional account. Practice, stats, and speedrun keep working when this is signed out.
@MainActor
final class AccountModel: NSObject, ObservableObject, ASWebAuthenticationSessionPresentationContextProviding {
    private let stats: StatsStore
    private var token: String?
    private var pendingState = ""
    private var webAuth: ASWebAuthenticationSession?
    weak var presentationWindow: NSWindow?

    var onOpenRace: (RaceTicket) -> Void = { _ in }
    var onShowAccount: () -> Void = {}

    @Published private(set) var user: AccountUser?
    @Published var usernameDraft = ""
    @Published var friendDraft = ""
    @Published var joinCode = ""
    @Published var raceRegion: PracticeChoice = .africa
    @Published var raceSubject: QuizSubject = .countries
    @Published var raceStyle: PracticeAnswerStyle = .clickMap
    @Published var leaderboardRegion: PracticeChoice = .world
    @Published var leaderboardSubject: QuizSubject = .countries
    @Published var leaderboardStyle: PracticeAnswerStyle = .clickMap
    @Published private(set) var friends = FriendLists(friends: [], incoming: [], outgoing: [])
    @Published private(set) var leaderboard: [LeaderboardRow] = []
    @Published private(set) var friendView: FriendStatsResponse?
    @Published private(set) var friendSnapshot = StatsSnapshot()
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var lastRace: RaceTicket?

    init(stats: StatsStore) {
        self.stats = stats
        super.init()
        token = KeychainStore.loadSession()
    }

    var isSignedIn: Bool { user != nil && token != nil }
    var needsUsername: Bool { user?.needsUsername == true }

    func restoreIfNeeded() {
        guard token != nil, user == nil else { return }
        Task { await restore() }
    }

    func signIn() {
        message = nil
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        pendingState = state
        var parts = URLComponents(url: MapLockAPI.url("/v1/auth/apple/start"), resolvingAgainstBaseURL: true)
        parts?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        guard let url = parts?.url else {
            message = Self.signInFailed
            return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "maplock") { [weak self] callback, error in
            Task { @MainActor in
                self?.finishWebSignIn(callback: callback, error: error)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webAuth = session
        busy = true
        if !session.start() {
            busy = false
            webAuth = nil
            message = Self.signInFailed
        }
    }

    func signOut() {
        token = nil
        user = nil
        KeychainStore.deleteSession()
        friends = FriendLists(friends: [], incoming: [], outgoing: [])
        leaderboard = []
        friendView = nil
        lastRace = nil
        message = "Signed out. Map Lock still works on this Mac."
    }

    func saveUsername() {
        guard let token else { return }
        let draft = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = AccountName.problem(with: draft) {
            message = problem
            return
        }
        Task {
            await run("Could not save that username") {
                user = try await AccountClient.setUsername(draft, token: token)
                usernameDraft = ""
                message = "Username saved."
                await refresh()
            }
        }
    }

    func addFriend() {
        guard let token else { return }
        let name = friendDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await run("Could not send the request") {
                try await AccountClient.requestFriend(name, token: token)
                friendDraft = ""
                message = "Friend request sent."
                friends = try await AccountClient.friends(token: token)
            }
        }
    }

    func accept(_ item: FriendItem) { decide(item, accept: true) }
    func decline(_ item: FriendItem) { decide(item, accept: false) }

    func remove(_ item: FriendItem) {
        guard let token else { return }
        Task {
            await run("Could not remove that friend") {
                try await AccountClient.removeFriend(item.userId, token: token)
                friends = try await AccountClient.friends(token: token)
            }
        }
    }

    func loadLeaderboard() {
        guard let token else { return }
        let key = SpeedrunKey.make(subject: leaderboardSubject, style: leaderboardStyle,
                                   scope: StatsScopeKey.from(practiceScope: leaderboardRegion.scope))
        Task {
            await run("Could not load the leaderboard") {
                leaderboard = try await AccountClient.leaderboard(key: key, token: token).rows
            }
        }
    }

    func openFriend(_ item: FriendItem) {
        guard let token, let name = item.username else { return }
        Task {
            await run("Could not open that friend's stats") {
                let response = try await AccountClient.friendStats(username: name, token: token)
                friendView = response
                friendSnapshot = StatsStore.previewSnapshot(response.stats)
            }
        }
    }

    func syncNow() {
        guard let token, user?.needsUsername == false else { return }
        Task { await sync(token: token) }
    }

    func createRace() {
        guard let token else { return }
        let region = raceRegion.scope.serverRegion
        let subject = raceSubject.rawValue
        let style = raceStyle.rawValue
        Task {
            await run("Could not create a race") {
                let ticket = try await AccountClient.createRace(region: region, subject: subject, style: style, token: token)
                lastRace = ticket
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ticket.webUrl, forType: .string)
                message = "Race link copied."
                onOpenRace(ticket)
            }
        }
    }

    func joinDraft() {
        handle(code: joinCode.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "maplock", url.host?.lowercased() != "auth" else { return }
        let code: String?
        if url.host?.lowercased() == "race" {
            code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        }
        guard let code, !code.isEmpty else { return }
        onShowAccount()
        handle(code: code)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? NSApp.keyWindow ?? ASPresentationAnchor()
    }

    private func finishWebSignIn(callback: URL?, error: Error?) {
        webAuth = nil
        if let error {
            busy = false
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                message = "Sign in was cancelled."
            } else {
                message = Self.signInFailed
            }
            return
        }
        guard let callback,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              state == pendingState else {
            busy = false
            message = Self.signInFailed
            return
        }
        Task {
            await run(Self.signInFailed) {
                let response = try await AccountClient.exchange(code: code, state: state)
                token = response.token
                user = response.user
                KeychainStore.saveSession(response.token)
                message = response.user.needsUsername ? "Pick a username." : "Signed in."
                if !response.user.needsUsername { await refresh() }
            }
        }
    }

    private static let signInFailed = "Sign in with Apple didn't finish. You can try again. Practice still works on this Mac."

    private func decide(_ item: FriendItem, accept: Bool) {
        guard let token else { return }
        Task {
            await run("Could not update that request") {
                if accept {
                    try await AccountClient.accept(item.id, token: token)
                } else {
                    try await AccountClient.decline(item.id, token: token)
                }
                friends = try await AccountClient.friends(token: token)
            }
        }
    }

    private func handle(code: String) {
        guard let token else {
            message = "Sign in to join a race. The code is \(code)."
            joinCode = code
            return
        }
        Task {
            await run("Could not join that race") {
                let ticket = try await AccountClient.joinRace(code: code, token: token)
                lastRace = ticket
                onOpenRace(ticket)
            }
        }
    }

    private func restore() async {
        guard let token else { return }
        do {
            user = try await AccountClient.me(token: token)
            if user?.needsUsername == false { await refresh() }
        } catch {
            self.token = nil
            KeychainStore.deleteSession()
        }
    }

    private func refresh() async {
        guard let token else { return }
        await sync(token: token)
        if let lists = try? await AccountClient.friends(token: token) { friends = lists }
        let key = SpeedrunKey.make(subject: leaderboardSubject, style: leaderboardStyle,
                                   scope: StatsScopeKey.from(practiceScope: leaderboardRegion.scope))
        if let board = try? await AccountClient.leaderboard(key: key, token: token) {
            leaderboard = board.rows
        }
    }

    private func sync(token: String) async {
        do {
            let merged = try await AccountClient.pushStats(stats.exportPayload(), token: token)
            stats.replace(with: merged)
        } catch let error as APIFailure {
            message = error.message
        } catch {
            message = "Could not sync stats. They are still saved on this Mac."
        }
    }

    private func run(_ fallback: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch let error as APIFailure {
            message = error.message
        } catch {
            message = fallback
        }
    }
}

