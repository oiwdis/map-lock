import AppKit
import AuthenticationServices
import SwiftUI

/// Optional account. Practice, stats, and speedrun keep working when this is signed out.
@MainActor
final class AccountModel: ObservableObject {
    private let stats: StatsStore
    private var token: String?
    private var pendingState = ""
    private var webAuth: ASWebAuthenticationSession?
    private let webPresenter = AppleSignInPresenter()
    weak var presentationWindow: NSWindow?

    var onOpenRace: (RaceTicket) -> Void = { _ in }
    var onShowAccount: () -> Void = {}
    var onStartSpeedrun: (PracticeChoice, QuizSubject, PracticeAnswerStyle) -> Void = { _, _, _ in }

    @Published private(set) var user: AccountUser?
    @Published var usernameDraft = ""
    @Published var loginUsername = ""
    @Published var loginPassword = ""
    @Published var confirmPassword = ""
    @Published var creatingAccount = false
    @Published var friendDraft = ""
    @Published var joinCode = ""
    @Published var raceRegion: PracticeChoice = .africa
    @Published var raceSubject: QuizSubject = .countries
    @Published var raceStyle: PracticeAnswerStyle = .clickMap
    @Published var leaderboardRegion: PracticeChoice = .africa
    @Published var page: AccountPage = .race
    @Published var justJoined = false
    @Published var clipboardCode: String?
    private var seededRaceOptions = false
    @Published var leaderboardSubject: QuizSubject = .countries
    @Published var leaderboardStyle: PracticeAnswerStyle = .clickMap
    @Published private(set) var friends = FriendLists(friends: [], incoming: [], outgoing: [])
    @Published private(set) var leaderboard: [LeaderboardRow] = []
    @Published private(set) var friendView: FriendStatsResponse?
    @Published private(set) var friendSnapshot = StatsSnapshot()
    @Published private(set) var busy = false
    @Published private(set) var syncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var signInKind: AccountSignInKind?
    @Published var message: String?
    @Published var lastRace: RaceTicket?

    init(stats: StatsStore) {
        self.stats = stats
        if let raw = UserDefaults.standard.string(forKey: Self.kindKey),
           let kind = AccountSignInKind(rawValue: raw) {
            signInKind = kind
        }
        if let pick = stats.latestSpeedrunPick() {
            leaderboardSubject = pick.subject
            leaderboardStyle = pick.style
            leaderboardRegion = pick.region
        }
        Task { @MainActor in
            token = await KeychainStore.loadSession()
            restoreIfNeeded()
        }
    }

    var isSignedIn: Bool { user != nil && token != nil }
    /// In-memory session. Keychain reads stay off the main thread.
    var sessionToken: String? { token }
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
        webPresenter.window = presentationWindow
        session.presentationContextProvider = webPresenter
        session.prefersEphemeralWebBrowserSession = false
        webAuth = session
        busy = true
        if !session.start() {
            busy = false
            webAuth = nil
            message = Self.signInFailed
        }
    }

    /// True when the request started. False when a field error was shown instead.
    @discardableResult
    func submitPasswordAccount() -> Bool {
        message = nil
        let name = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = AccountName.problem(with: name) {
            message = problem
            return false
        }
        if loginPassword.count < 8 || loginPassword.count > 200 {
            message = "Use 8 or more characters."
            return false
        }
        if creatingAccount && loginPassword != confirmPassword {
            message = "Those passwords don't match. Type the same password in both boxes."
            return false
        }
        let password = loginPassword
        let making = creatingAccount
        loginPassword = ""
        confirmPassword = ""
        Task {
            await run(making ? "Could not create the account. Try again." : "Wrong username or password. Try again, or create an account.") {
                let response: AuthResponse
                if making {
                    response = try await AccountClient.register(username: name, password: password)
                } else {
                    response = try await AccountClient.login(username: name, password: password)
                }
                token = response.token
                user = response.user
                KeychainStore.saveSession(response.token)
                rememberKind(.password)
                loginUsername = ""
                creatingAccount = false
                justJoined = making && !response.user.needsUsername
                message = nil
                if !response.user.needsUsername {
                    await refresh()
                    joinPendingCode()
                }
            }
        }
        return true
    }

    func setCreatingAccount(_ creating: Bool) {
        guard creatingAccount != creating else { return }
        creatingAccount = creating
        confirmPassword = ""
        message = nil
    }

    func toggleCreateAccount() {
        setCreatingAccount(!creatingAccount)
    }

    func signOut() {
        token = nil
        user = nil
        loginUsername = ""
        loginPassword = ""
        confirmPassword = ""
        creatingAccount = false
        lastSyncedAt = nil
        clearKind()
        KeychainStore.deleteSession()
        friends = FriendLists(friends: [], incoming: [], outgoing: [])
        leaderboard = []
        friendView = nil
        lastRace = nil
        justJoined = false
        clipboardCode = nil
        page = .race
        message = nil
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
                joinPendingCode()
            }
        }
    }

    func addFriend() {
        guard let token else { return }
        let name = friendDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = "Type a username first."
            return
        }
        Task {
            await run("Could not send that request. Check your connection and try again.") {
                try await AccountClient.requestFriend(name, token: token)
                friendDraft = ""
                message = "Request sent. They need to accept."
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

    func closeFriend() {
        friendView = nil
        friendSnapshot = StatsSnapshot()
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

    func createRace(telling name: String? = nil) {
        guard let token else { return }
        let region = raceRegion.scope.serverRegion
        let subject = raceSubject.rawValue
        let style = raceStyle.rawValue
        Task {
            await run("Could not create a race. Try again.") {
                let ticket = try await AccountClient.createRace(region: region, subject: subject, style: style, token: token)
                lastRace = ticket
                copyRaceLink(ticket)
                message = name.map { "Link copied. Send it to \($0)." } ?? "Link copied."
                page = .race
                onOpenRace(ticket)
            }
        }
    }

    func copyLastRaceLink() {
        guard let lastRace else { return }
        copyRaceLink(lastRace)
        message = "Link copied."
    }

    private func joinPendingCode() {
        guard RaceLink.code(in: joinCode) != nil else { return }
        joinDraft()
    }

    func joinDraft() {
        let raw = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = RaceLink.code(in: raw) ?? raw
        joinCode = code
        handle(code: code)
    }

    func joinClipboard() {
        guard let clipboardCode else { return }
        joinCode = clipboardCode
        self.clipboardCode = nil
        handle(code: joinCode)
    }

    func refreshClipboardOffer() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let code = RaceLink.code(in: text)
        clipboardCode = (code == nil || code == lastRace?.code) ? nil : code
    }

    func beginSpeedrun() {
        onStartSpeedrun(leaderboardRegion, leaderboardSubject, leaderboardStyle)
    }

    func seedRaceOptions(subject: QuizSubject, style: PracticeAnswerStyle) {
        guard !seededRaceOptions else { return }
        seededRaceOptions = true
        raceSubject = subject
        raceStyle = style
    }

    func dismissWelcome() {
        justJoined = false
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "maplock", url.host?.lowercased() != "auth" else { return }
        guard let code = RaceLink.code(from: url) else { return }
        page = .race
        onShowAccount()
        handle(code: code)
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
                rememberKind(.apple)
                message = response.user.needsUsername ? "Pick a username." : nil
                justJoined = false
                if !response.user.needsUsername {
                    await refresh()
                    joinPendingCode()
                }
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
            user = nil
            clearKind()
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
        syncing = true
        defer { syncing = false }
        do {
            let merged = try await AccountClient.pushStats(stats.exportPayload(), token: token)
            stats.replace(with: merged)
            lastSyncedAt = Date()
        } catch let error as APIFailure {
            message = error.message
        } catch {
            message = "Could not sync stats. They are still saved on this Mac."
        }
    }

    private static let kindKey = "maplock.signInKind"

    private func rememberKind(_ kind: AccountSignInKind) {
        signInKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey)
    }

    private func clearKind() {
        signInKind = nil
        UserDefaults.standard.removeObject(forKey: Self.kindKey)
    }

    private func run(_ fallback: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch let error as APIFailure {
            message = Self.friendlier(error.message)
        } catch {
            message = Self.friendlier(fallback)
        }
    }

    private func copyRaceLink(_ ticket: RaceTicket) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ticket.webUrl, forType: .string)
    }

    /// Turns worker wording into a short next step.
    private static func friendlier(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("no player") { return "No one uses that username. Check the spelling." }
        if lower.contains("cannot add yourself") || lower.contains("that's you") { return "That's you." }
        if lower.contains("already friends") { return "You're already friends." }
        if lower.contains("already waiting") { return "You already asked. They still need to accept." }
        if lower.contains("wrong username or password") {
            return "Wrong username or password. Try again, or create an account."
        }
        if lower.contains("username is taken") { return "That username is taken. Try another." }
        if lower.contains("unknown race") { return "That code does not match a race. Check it and try again." }
        return raw
    }
}

enum AccountPage: String, CaseIterable, Identifiable {
    case race, board, friends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .race: return "Race"
        case .board: return "Leaderboard"
        case .friends: return "Friends"
        }
    }
}

enum AccountSignInKind: String {
    case apple
    case password

    var caption: String {
        switch self {
        case .apple: return "Signed in with Apple"
        case .password: return "Username & password"
        }
    }
}

/// Pulls a race code out of a pasted link, a maplock URL, or a bare code.
enum RaceLink {
    static func code(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let code = code(from: url) { return code }
        if let range = trimmed.range(of: "/race/", options: .caseInsensitive) {
            let token = trimmed[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
            if (4...16).contains(token.count) { return String(token) }
        }
        let compact = trimmed.uppercased()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        guard (4...16).contains(compact.count),
              compact.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return compact
    }

    static func code(from url: URL) -> String? {
        if url.scheme?.lowercased() == "maplock" {
            if url.host?.lowercased() == "auth" { return nil }
            if url.host?.lowercased() == "race" {
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if (4...16).contains(path.count) { return path }
            }
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0].lowercased() == "race", (4...16).contains(parts[1].count) {
            return parts[1]
        }
        return nil
    }
}

/// Presents the Sign in with Apple sheet. This stays a plain NSObject so the
/// @objc presentation callback is not isolated to the main actor.
final class AppleSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var window: NSWindow?

    @objc(presentationAnchorForWebAuthenticationSession:)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Apple calls this on the main thread. assumeIsolated keeps the AppKit
        // lookup on the main actor without making this @objc method isolated.
        MainActor.assumeIsolated {
            window ?? NSApp.keyWindow ?? ASPresentationAnchor()
        }
    }
}

