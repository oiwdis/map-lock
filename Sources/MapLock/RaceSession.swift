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
    var finished: Bool
    var elapsed: Double?
    var forfeited: Bool
    var wantsRematch: Bool
}

private struct RaceEnvelope: Decodable {
    var type: String
    var race: RaceWireState
}

/// One live race. The country order comes from the server seed, not a fresh shuffle.
@MainActor
final class RaceSession: ObservableObject {
    let ticket: RaceTicket
    let world: [Country]
    let scope: PracticeScope
    private var seed: String
    private(set) var order: [String]
    private let byName: [String: Country]
    private let stats: StatsStore
    private let token: String
    private var progress: SpeedrunProgress
    private var socket: URLSessionWebSocketTask?
    private var myUserId: String?
    private var recorded = false
    private var flashTask: Task<Void, Never>?
    private var flashToken = 0

    @Published private(set) var phase = "waiting"
    @Published private(set) var countdown: Int?
    @Published private(set) var index = 0
    @Published private(set) var misses = 0
    @Published private(set) var flashCountry: String?
    @Published private(set) var shakeCount = 0
    @Published private(set) var opponentName = "Opponent"
    @Published private(set) var opponentFound = 0
    @Published private(set) var opponentTotal = 0
    @Published private(set) var opponentMisses = 0
    @Published private(set) var youElapsed: Double?
    @Published private(set) var opponentElapsed: Double?
    @Published private(set) var youForfeited = false
    @Published private(set) var opponentForfeited = false
    @Published private(set) var youWon: Bool?
    @Published private(set) var status = "Waiting for the other player"
    @Published var clockStart: Date?

    var onClose: () -> Void = {}

    init(ticket: RaceTicket, world: [Country], scope: PracticeScope, token: String, userId: String, stats: StatsStore) {
        self.ticket = ticket
        self.world = world
        self.scope = scope
        self.seed = ticket.seed
        self.token = token
        self.myUserId = userId
        self.stats = stats
        let names = SpeedrunPool.names(world: world, scope: scope).sorted()
        var generator = SeededGenerator(seedHex: ticket.seed)
        let shuffled = SpeedrunRules.shuffled(names, using: &generator)
        self.order = shuffled
        self.progress = SpeedrunProgress(order: shuffled)
        self.byName = Dictionary(world.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        opponentTotal = shuffled.count
    }

    var total: Int { order.count }
    var currentCountry: Country? {
        guard let name = progress.current else { return nil }
        return byName[name]
    }
    var progressText: String {
        guard total > 0 else { return "0 of 0" }
        return "\(min(index + 1, total)) of \(total)"
    }
    var canClick: Bool { phase == "racing" && progress.current != nil }
    var clockRunning: Bool { phase == "racing" && clockStart != nil && youElapsed == nil }

    func connect() {
        var request = URLRequest(url: websocketURL(code: ticket.code))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        listen()
        sendJSON(("type", "ready"), ("total", total))
    }

    func click(_ name: String) {
        guard canClick else { return }
        switch progress.click(name) {
        case .ignored:
            return
        case .miss:
            misses = progress.misses
            shakeCount += 1
            flash(name)
            sendProgress(finished: false)
        case .advanced:
            clearFlash()
            index = progress.index
            sendProgress(finished: false)
        case .finished:
            clearFlash()
            index = progress.index
            sendProgress(finished: true)
        }
    }

    func forfeit() {
        sendJSON(("type", "forfeit"))
    }

    func rematch() {
        sendJSON(("type", "rematch"))
        status = "Waiting for the other player to rematch."
    }

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onClose()
    }

    func timeText(at now: Date) -> String {
        guard let clockStart else { return SpeedrunClock.format(0) }
        return SpeedrunClock.format(now.timeIntervalSince(clockStart))
    }

    private func listen() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.status = "Connection lost. If you were racing, reconnect by opening the link again."
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
            var generator = SeededGenerator(seedHex: seed)
            order = SpeedrunRules.shuffled(SpeedrunPool.names(world: world, scope: scope).sorted(), using: &generator)
            progress = SpeedrunProgress(order: order)
            index = 0
            misses = 0
            clockStart = nil
            recorded = false
            youElapsed = nil
            youWon = nil
            youForfeited = false
            opponentElapsed = nil
            opponentForfeited = false
            sendJSON(("type", "ready"), ("total", order.count))
        }
        phase = race.phase
        countdown = race.countdown
        let mine = race.players.first { $0.userId == myUserId } ?? race.players.first
        let other = race.players.first { $0.userId != mine?.userId }
        if let mine {
            myUserId = mine.userId
            youElapsed = mine.elapsed
            youForfeited = mine.forfeited
        }
        if let other {
            opponentName = other.username
            opponentFound = other.found
            opponentTotal = other.total > 0 ? other.total : total
            opponentMisses = other.misses
            opponentElapsed = other.elapsed
            opponentForfeited = other.forfeited
        }
        if race.phase == "racing", clockStart == nil { clockStart = Date() }
        if race.phase == "finished" {
            if let winner = race.winnerId, let mine = myUserId {
                youWon = winner == mine
            }
            status = youForfeited ? "You forfeited." : (opponentForfeited ? "\(opponentName) forfeited." : "Race finished.")
            recordLocalFinish()
        } else if race.phase == "countdown" {
            status = "Get ready"
        } else if race.phase == "waiting" {
            status = race.players.count < 2 ? "Waiting for the other player" : "Waiting to start"
        }
    }

    private func sendProgress(finished: Bool) {
        sendJSON(
            ("type", "progress"),
            ("found", index),
            ("total", total),
            ("misses", misses),
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

    private func recordLocalFinish() {
        guard !recorded, !youForfeited, index >= total, total > 0, let duration = youElapsed, duration > 0 else { return }
        recorded = true
        stats.recordSpeedrun(scope: StatsScopeKey.from(practiceScope: scope), duration: duration,
                             misses: misses, countries: total)
    }

    private func flash(_ name: String) {
        flashToken += 1
        let token = flashToken
        flashCountry = name
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, self.flashToken == token else { return }
            self.flashCountry = nil
        }
    }

    private func clearFlash() {
        flashTask?.cancel()
        flashToken += 1
        flashCountry = nil
    }

    private func websocketURL(code: String) -> URL {
        let http = MapLockAPI.url("/v1/races/\(code)/ws")
        var parts = URLComponents(url: http, resolvingAgainstBaseURL: true)
        if parts?.scheme == "https" { parts?.scheme = "wss" }
        if parts?.scheme == "http" { parts?.scheme = "ws" }
        return parts?.url ?? http
    }
}
