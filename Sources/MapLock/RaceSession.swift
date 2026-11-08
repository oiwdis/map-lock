import Combine
import Foundation

struct RaceWireState: Decodable {
    var code: String
    var region: String
    var seed: String
    var phase: String
    var countdown: Int?
    var startedAt: Double?
    var serverNow: Double?
    var decided: Bool?
    var tie: Bool?
    var winnerId: String?
    var reason: String?
    var notice: String?
    var noticeName: String?
    var players: [RaceWirePlayer]
}

enum ChallengeEnd: Equatable {
    case declined(String)
    case expired(String)

    var person: String {
        switch self {
        case .declined(let name), .expired(let name): return name
        }
    }

    var message: String {
        switch self {
        case .declined(let name): return "\(name) declined your challenge"
        case .expired(let name): return "\(name) didn't respond"
        }
    }
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
    var dnf: Bool?
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
    @Published private(set) var youFinished = false
    @Published private(set) var opponentFinished = false
    @Published private(set) var youDnf = false
    @Published private(set) var opponentDnf = false
    @Published private(set) var youMisses = 0
    @Published private(set) var youSkips = 0
    @Published private(set) var youFound = 0
    @Published private(set) var youTotal = 0
    @Published private(set) var decided = false
    @Published private(set) var tie = false
    @Published private(set) var reason: String?
    @Published private(set) var isPersonalBest = false
    @Published private(set) var youWon: Bool?
    @Published private(set) var status = "Waiting for your friend"
    @Published private(set) var challengeEnd: ChallengeEnd?
    @Published private(set) var inviteNote: String?
    @Published private(set) var opponentJoined = false

    var onClose: () -> Void = {}
    var onCancelled: () -> Void = {}
    var onLeft: (String) -> Void = { _ in }
    var onRematch: (RaceTicket) -> Void = { _ in }
    var onChangeRegion: () -> Void = {}
    var onGiveUp: () -> Void = {}
    var onFinished: (String) -> Void = { _ in }
    private var waitPoll: Task<Void, Never>?
    private var clockStart: Date?
    private var recordedTime = false
    private var notedFinish = false
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
        startWaitPoll()
    }

    func forfeit() {
        sendJSON(("type", "forfeit"))
    }

    func rematch() {
        Task {
            do {
                let created = try await AccountClient.createRace(
                    region: ticket.region, subject: ticket.subject, style: ticket.style,
                    countries: ticket.countries, token: token
                )
                try await AccountClient.inviteToRace(code: created.code, username: opponentName, token: token)
                onRematch(created)
            } catch let error as APIFailure {
                status = error.message
            } catch {
                status = "Could not start a rematch."
            }
        }
    }

    func changeRegion() {
        onChangeRegion()
    }

    func challengeAgain() {
        guard let name = challengeEnd?.person, !name.isEmpty else { return }
        Task {
            do {
                let created = try await AccountClient.createRace(
                    region: ticket.region, subject: ticket.subject, style: ticket.style,
                    countries: ticket.countries, token: token
                )
                try await AccountClient.inviteToRace(code: created.code, username: name, token: token)
                onRematch(created)
            } catch let error as APIFailure {
                status = error.message
            } catch {
                status = "Could not send another challenge."
            }
        }
    }

    func giveUp() {
        onGiveUp()
    }

    func leaveWaiting() {
        sendJSON(("type", "leave"))
        onLeft(ticket.code)
        close()
    }

    /// Opponent's clock, using the server start so both Macs agree.
    func opponentRunning(at now: Date) -> Double {
        if opponentFinished || opponentDnf { return opponentElapsed ?? 0 }
        guard let clockStart else { return opponentElapsed ?? 0 }
        let raw = max(0, now.timeIntervalSince(clockStart))
        return raw + Double(opponentMisses * 3 + opponentSkips * 10)
    }

    func close() {
        dropSocket()
        onClose()
    }

    func dropSocket() {
        waitPoll?.cancel()
        waitPoll = nil
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
            youFinished = false
            youDnf = false
            opponentElapsed = nil
            opponentForfeited = false
            opponentFinished = false
            opponentDnf = false
            decided = false
            tie = false
            isPersonalBest = false
            recordedTime = false
            notedFinish = false
            clockStart = nil
            opponentFound = 0
            opponentMisses = 0
            opponentSkips = 0
            sendJSON(("type", "ready"), ("total", order.count))
        }
        phase = race.phase
        countdown = race.countdown
        decided = race.decided ?? false
        tie = race.tie ?? false
        reason = race.reason
        if let started = race.startedAt, let serverNow = race.serverNow, clockStart == nil {
            let offset = Date().timeIntervalSince1970 - serverNow / 1000
            clockStart = Date(timeIntervalSince1970: started / 1000 + offset)
        }
        let mine = race.players.first { $0.userId == myUserId } ?? race.players.first
        let other = race.players.first { $0.userId != mine?.userId }
        if let mine {
            myUserId = mine.userId
            youElapsed = mine.elapsed
            youRaw = mine.raw
            youForfeited = mine.forfeited
            youFinished = mine.finished
            youDnf = mine.dnf ?? false
            youMisses = mine.misses
            youSkips = mine.skips ?? 0
            youFound = mine.found
            youTotal = mine.total > 0 ? mine.total : order.count
            if mine.finished, !(mine.dnf ?? false), !mine.forfeited, !recordedTime, let elapsed = mine.elapsed {
                recordedTime = true
                let key = SpeedrunKey.make(
                    subject: QuizSubject(rawValue: ticket.subject) ?? .countries,
                    style: PracticeAnswerStyle(rawValue: ticket.style) ?? .clickMap,
                    place: scope.placeKey
                )
                isPersonalBest = stats.recordSpeedrun(
                    key: key, duration: elapsed, misses: mine.misses, countries: mine.found
                ).isNewBest
            }
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
            opponentFinished = other.finished
            opponentDnf = other.dnf ?? false
        }
        if race.tie == true {
            youWon = nil
        } else if let winner = race.winnerId {
            youWon = winner == myUserId
        } else {
            youWon = nil
        }
        if race.phase == "racing" {
            quiz.speedrunAcceptsInput = !youFinished
            if !youFinished { quiz.noteSpeedrunVisible() }
            status = "Go"
        } else if race.phase == "finished" {
            quiz.speedrunAcceptsInput = false
            if youForfeited {
                status = "You forfeited."
            } else if opponentForfeited {
                status = "\(opponentName) forfeited."
            } else if youWon == true {
                status = "You win on final time."
            } else if youWon == false {
                status = "\(opponentName) wins on final time."
            } else if tie {
                status = "Tie."
            } else {
                status = "Race finished."
            }
            if !notedFinish {
                notedFinish = true
                onFinished(ticket.code)
            }
        } else if race.phase == "cancelled" {
            ended = true
            quiz.speedrunAcceptsInput = false
            noteClosed(notice: race.notice, name: race.noticeName)
        } else if race.phase == "countdown" {
            quiz.speedrunAcceptsInput = false
            status = "Get ready"
        } else {
            quiz.speedrunAcceptsInput = false
            status = race.players.count < 2 ? "Waiting for your friend" : "Waiting to start"
        }
    }

    private func startWaitPoll() {
        guard isHost else { return }
        waitPoll?.cancel()
        waitPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.challengeEnd == nil, self.phase == "waiting" else { continue }
                guard let note = try? await AccountClient.raceWait(code: self.ticket.code, token: self.token) else { continue }
                self.applyWait(note)
            }
        }
    }

    private func applyWait(_ note: RaceWaitNote) {
        guard note.phase == "cancelled", challengeEnd == nil else { return }
        phase = "cancelled"
        ended = true
        quiz.speedrunAcceptsInput = false
        noteClosed(notice: note.notice, name: note.noticeName)
    }

    private func noteClosed(notice: String?, name: String?) {
        let person = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notice == "declined", !person.isEmpty {
            challengeEnd = .declined(person)
            status = challengeEnd?.message ?? status
        } else if notice == "expired", !person.isEmpty {
            challengeEnd = .expired(person)
            status = challengeEnd?.message ?? status
        } else if challengeEnd == nil {
            status = "This race was cancelled."
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
            recordsResult: false, onClose: onClose
        )
    }
}
