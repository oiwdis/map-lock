import Combine
import Foundation

struct RaceWireState: Decodable {
    var code: String
    var region: String
    var seed: String
    var phase: String
    var countdown: Int?
    var winnerId: String?
    var players: [RaceWirePlayer]
}

struct RaceWirePlayer: Decodable {
    var userId: String
    var username: String
    var connected: Bool
    var found: Int
    var total: Int
    var misses: Int
    var skips: Int?
    var finished: Bool
    var elapsed: Double?
    var raw: Double?
    var forfeited: Bool
    var wantsRematch: Bool
}

private struct RaceEnvelope: Decodable {
    var type: String
    var race: RaceWireState
}

/// Live race socket plus the speedrun quiz both players share.
@MainActor
final class RaceSession: ObservableObject {
    let ticket: RaceTicket
    let world: [Country]
    let scope: PracticeScope
    private var seed: String
    private var order: [String]
    private let stats: StatsStore
    private let token: String
    private var socket: URLSessionWebSocketTask?
    private var myUserId: String
    let isHost: Bool
    private var ended = false

    @Published private(set) var quiz: QuizSession
    @Published private(set) var phase = "waiting"
    @Published private(set) var countdown: Int?
    @Published private(set) var opponentName = "Opponent"
    @Published private(set) var opponentFound = 0
    @Published private(set) var opponentTotal = 0
    @Published private(set) var opponentMisses = 0
    @Published private(set) var opponentSkips = 0
    @Published private(set) var youElapsed: Double?
    @Published private(set) var youRaw: Double?
    @Published private(set) var opponentElapsed: Double?
    @Published private(set) var opponentRaw: Double?
    @Published private(set) var youForfeited = false
    @Published private(set) var opponentForfeited = false
    @Published private(set) var youWon: Bool?
    @Published private(set) var status = "Waiting for your friend"
    @Published private(set) var inviteNote: String?
    @Published private(set) var opponentJoined = false

    var onClose: () -> Void = {}
    var onCancelled: () -> Void = {}
    /// Usernames the host can invite from the waiting screen.
    var friendNames: [String] = []
    var canOfferCancel: Bool { isHost && phase == "waiting" && !opponentJoined }

    func invite(username: String) {
        guard isHost, phase == "waiting" else { return }
        Task {
            do {
                try await AccountClient.inviteToRace(code: ticket.code, username: username, token: token)
                inviteNote = "Invited \(username)."
            } catch let error as APIFailure {
                status = error.message
            } catch {
                status = "Could not send the invite."
            }
        }
    }

    init(ticket: RaceTicket, world: [Country], scope: PracticeScope, token: String, userId: String,
         isHost: Bool, stats: StatsStore) {
        self.ticket = ticket
        self.world = world
        self.scope = scope
        self.seed = ticket.seed
        self.token = token
        self.myUserId = userId
        self.isHost = isHost
        self.stats = stats
        let built = Self.order(world: world, scope: scope, seed: ticket.seed)
        self.order = built
        self.opponentTotal = built.count
        self.quiz = Self.makeQuiz(ticket: ticket, world: world, scope: scope, order: built, stats: stats, onClose: {})
        self.quiz.onSpeedrunProgress = { [weak self] found, total, misses, skips, finished in
            self?.sendProgressValues(found: found, total: total, misses: misses, skips: skips, finished: finished)
        }
        self.quiz.onClose = { [weak self] in self?.close() }
        self.quiz.speedrunAcceptsInput = false
    }

    func connect() {
        var request = URLRequest(url: websocketURL(code: ticket.code))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        listen()
        sendJSON(("type", "ready"), ("total", order.count))
    }

    func forfeit() {
        sendJSON(("type", "forfeit"))
    }

    func rematch() {
        sendJSON(("type", "rematch"))
        status = "Waiting for the other player to rematch."
    }

    func close() {
        dropSocket()
        onClose()
    }

    func dropSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func cancelAndClose() {
        guard canOfferCancel, !ended else { return }
        ended = true
        Task {
            do {
                try await AccountClient.cancelRace(code: ticket.code, token: token)
                onCancelled()
                close()
            } catch let error as APIFailure {
                ended = false
                status = error.message
            } catch {
                ended = false
                status = "Could not cancel the race. Try again."
            }
        }
    }

    private func listen() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    if !self.ended && self.phase != "cancelled" {
                        self.status = "Connection lost. If you were racing, reconnect by opening the link again."
                    }
                case .success(let message):
                    if case .string(let text) = message { self.apply(text) }
                    self.listen()
                }
            }
        }
    }

    private func apply(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RaceEnvelope.self, from: data) else { return }
        let race = envelope.race
        if race.seed != seed {
            seed = race.seed
            order = Self.order(world: world, scope: scope, seed: seed)
            opponentTotal = order.count
            let next = Self.makeQuiz(ticket: ticket, world: world, scope: scope, order: order, stats: stats) { [weak self] in
                self?.close()
            }
            next.onSpeedrunProgress = { [weak self] found, total, misses, skips, finished in
                self?.sendProgressValues(found: found, total: total, misses: misses, skips: skips, finished: finished)
            }
            next.speedrunAcceptsInput = false
            quiz = next
            youElapsed = nil
            youWon = nil
            youForfeited = false
            opponentElapsed = nil
            opponentForfeited = false
            opponentFound = 0
            opponentMisses = 0
            opponentSkips = 0
            sendJSON(("type", "ready"), ("total", order.count))
        }
        phase = race.phase
        countdown = race.countdown
        let mine = race.players.first { $0.userId == myUserId } ?? race.players.first
        let other = race.players.first { $0.userId != mine?.userId }
        if let mine {
            myUserId = mine.userId
            youElapsed = mine.elapsed
            youRaw = mine.raw
            youForfeited = mine.forfeited
        }
        opponentJoined = other != nil
        if let other {
            opponentName = other.username
            opponentFound = other.found
            opponentTotal = other.total > 0 ? other.total : order.count
            opponentMisses = other.misses
            opponentSkips = other.skips ?? 0
            opponentElapsed = other.elapsed
            opponentRaw = other.raw
            opponentForfeited = other.forfeited
        }
        if race.phase == "racing" {
            quiz.speedrunAcceptsInput = true
            quiz.noteSpeedrunVisible()
            status = "Go"
        } else if race.phase == "finished" {
            quiz.speedrunAcceptsInput = false
            if let winner = race.winnerId {
                youWon = winner == myUserId
            }
            if youForfeited {
                status = "You forfeited."
            } else if opponentForfeited {
                status = "\(opponentName) forfeited."
            } else if youWon == true {
                status = "You win on final time."
            } else if youWon == false {
                status = "\(opponentName) wins on final time."
            } else {
                status = "Race finished."
            }
        } else if race.phase == "cancelled" {
            ended = true
            quiz.speedrunAcceptsInput = false
            status = "This race was cancelled."
        } else if race.phase == "countdown" {
            quiz.speedrunAcceptsInput = false
            status = "Get ready"
        } else {
            quiz.speedrunAcceptsInput = false
            status = race.players.count < 2 ? "Waiting for your friend" : "Waiting to start"
        }
    }

    private func sendProgressValues(found: Int, total: Int, misses: Int, skips: Int, finished: Bool) {
        sendJSON(
            ("type", "progress"),
            ("found", found),
            ("total", total),
            ("misses", misses),
            ("skips", skips),
            ("finished", finished)
        )
    }

    private func sendJSON(_ pairs: (String, Any)...) {
        var body: [String: Any] = [:]
        for (key, value) in pairs { body[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func websocketURL(code: String) -> URL {
        let http = MapLockAPI.url("/v1/races/\(code)/ws")
        var parts = URLComponents(url: http, resolvingAgainstBaseURL: true)
        if parts?.scheme == "https" { parts?.scheme = "wss" }
        if parts?.scheme == "http" { parts?.scheme = "ws" }
        return parts?.url ?? http
    }

    private static func order(world: [Country], scope: PracticeScope, seed: String) -> [String] {
        var generator = SeededGenerator(seedHex: seed)
        return SpeedrunRules.shuffled(SpeedrunPool.names(world: world, scope: scope).sorted(), using: &generator)
    }

    private static func makeQuiz(ticket: RaceTicket, world: [Country], scope: PracticeScope, order: [String],
                                 stats: StatsStore, onClose: @escaping () -> Void) -> QuizSession {
        let subject = QuizSubject(rawValue: ticket.subject) ?? .countries
        let style = PracticeAnswerStyle(rawValue: ticket.style) ?? .clickMap
        let pair = style.enginePair
        let suite = "maplock.race.\(ticket.code).\(ticket.seed)"
        if let box = UserDefaults(suiteName: suite) {
            box.removePersistentDomain(forName: suite)
        }
        let deck = DeckStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        return QuizSession(
            world: world, pool: order, mode: pair.mode, quizType: pair.type, subject: subject,
            stats: stats, deck: deck, count: max(order.count, 1), kind: .practice,
            mapScope: scope, speedrun: true, speedrunStyle: style, speedrunOrder: order,
            onClose: onClose
        )
    }
}
