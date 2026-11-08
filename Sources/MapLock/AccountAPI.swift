import Foundation
import CryptoKit

enum MapLockAPI {
    /// Override with UserDefaults `maplock.apiBase` while using `wrangler dev`.
    static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: "maplock.apiBase"),
           let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return URL(string: "https://map-lock.elliot-7c9.workers.dev")!
    }

    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL) ?? baseURL
    }
}

struct APIFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AccountUser: Codable, Equatable {
    var id: String
    var username: String?
    var needsUsername: Bool
}

struct AuthResponse: Codable {
    var token: String
    var user: AccountUser
}

struct FriendItem: Codable, Identifiable, Equatable {
    var id: String
    var userId: String
    var username: String?
}

struct FriendLists: Codable, Equatable {
    var friends: [FriendItem]
    var incoming: [FriendItem]
    var outgoing: [FriendItem]
}

struct FriendRequestResponse: Codable {
    var ok: Bool?
    var id: String?
    var status: String?
    var username: String?
}

struct LeaderboardRow: Codable, Identifiable, Equatable {
    var userId: String
    var username: String
    var you: Bool
    var time: Double?
    var id: String { userId }
}

struct LeaderboardResponse: Codable {
    var region: String
    var rows: [LeaderboardRow]
}

struct RaceInvite: Codable, Identifiable, Equatable {
    var id: String
    var raceCode: String
    var fromUserId: String
    var fromUsername: String
    var region: String
    var subject: String
    var style: String
    var createdAt: Int

    var countries: [String]?

    var placeName: String {
        if region == "custom" {
            if let countries, countries.count >= 2 {
                return CustomSets.displayTitle(countries: countries)
            }
            return "Custom"
        }
        return region == "world" ? "Whole world" : region
    }

    var sentence: String { "\(fromUsername) challenged you to a race (\(placeName))" }
}

struct RaceHistoryPlayer: Codable {
    var userId: String
    var username: String
    var found: Int
    var total: Int
    var misses: Int
    var skips: Int?
    var finished: Bool
    var raw: Double?
    var elapsed: Double?
    var forfeited: Bool
    var dnf: Bool?
}

struct RaceHistoryRace: Codable {
    var winnerId: String?
    var tie: Bool?
    var reason: String?
    var players: [RaceHistoryPlayer]
}

struct RaceHistoryItem: Codable, Identifiable {
    var code: String
    var region: String
    var subject: String
    var style: String
    var finishedAt: Int
    var race: RaceHistoryRace?
    var id: String { code }

    var countries: [String]?

    var placeName: String {
        if region == "custom" {
            if let countries, countries.count >= 2 {
                return CustomSets.displayTitle(countries: countries)
            }
            return "Custom"
        }
        return region == "world" ? "Whole world" : region
    }
}

struct RaceTicket: Codable, Equatable {
    var code: String
    var region: String
    var seed: String
    var subject: String
    var style: String
    var countries: [String]?
    var webUrl: String
    var appUrl: String

    /// Continent, world, or the country list stored with a custom race.
    var practiceScope: PracticeScope? {
        if region == "custom", let countries, countries.count >= 2 {
            return .custom(countries: countries)
        }
        return PracticeScope.fromServer(region)
    }
}

private struct RaceCreateBody: Encodable {
    var region: String
    var subject: String
    var style: String
    var countries: [String]?
}

struct FriendStatsResponse: Codable {
    var username: String
    var stats: SyncPayload
}

enum AccountClient {
    static func register(username: String, password: String) async throws -> AuthResponse {
        try await send(AuthResponse.self, path: "/v1/auth/register", method: "POST", token: nil,
                       json: try encode(["username": username, "password": password]))
    }

    static func login(username: String, password: String) async throws -> AuthResponse {
        try await send(AuthResponse.self, path: "/v1/auth/login", method: "POST", token: nil,
                       json: try encode(["username": username, "password": password]))
    }

    static func exchange(code: String, state: String) async throws -> AuthResponse {
        try await send(AuthResponse.self, path: "/v1/auth/exchange", method: "POST", token: nil,
                       json: try encode(["code": code, "state": state]))
    }

    /// Native identity-token sign-in. The app uses the web flow; this stays for the worker.
    static func signIn(identityToken: String, nonce: String) async throws -> AuthResponse {
        try await send(AuthResponse.self, path: "/v1/auth/apple", method: "POST", token: nil,
                       json: try encode(["identityToken": identityToken, "nonce": nonce]))
    }

    static func me(token: String) async throws -> AccountUser {
        struct Box: Codable { var user: AccountUser }
        return try await send(Box.self, path: "/v1/me", method: "GET", token: token, json: nil).user
    }

    static func setUsername(_ username: String, token: String) async throws -> AccountUser {
        struct Box: Codable { var user: AccountUser }
        return try await send(Box.self, path: "/v1/me/username", method: "POST", token: token,
                              json: try encode(["username": username])).user
    }

    static func friends(token: String) async throws -> FriendLists {
        try await send(FriendLists.self, path: "/v1/friends", method: "GET", token: token, json: nil)
    }

    static func requestFriend(_ username: String, token: String) async throws -> FriendRequestResponse {
        try await send(FriendRequestResponse.self, path: "/v1/friends/requests", method: "POST", token: token,
                       json: try encode(["username": username]))
    }

    static func accept(_ id: String, token: String) async throws {
        try await sendEmpty(path: "/v1/friends/requests/\(id)/accept", method: "POST", token: token,
                            json: try encode([String: String]()))
    }

    static func decline(_ id: String, token: String) async throws {
        try await sendEmpty(path: "/v1/friends/requests/\(id)/decline", method: "POST", token: token,
                            json: try encode([String: String]()))
    }

    static func removeFriend(_ userId: String, token: String) async throws {
        try await sendEmpty(path: "/v1/friends/\(userId)", method: "DELETE", token: token, json: nil)
    }

    static func leaderboard(key: String, token: String) async throws -> LeaderboardResponse {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "|")
        let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return try await send(LeaderboardResponse.self, path: "/v1/leaderboard?key=\(encoded)",
                               method: "GET", token: token, json: nil)
    }

    static func friendStats(username: String, token: String) async throws -> FriendStatsResponse {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return try await send(FriendStatsResponse.self, path: "/v1/users/\(encoded)/stats",
                               method: "GET", token: token, json: nil)
    }

    static func pushStats(_ payload: SyncPayload, token: String) async throws -> SyncPayload {
        struct Box: Codable { var stats: SyncPayload }
        return try await send(Box.self, path: "/v1/me/stats", method: "PUT", token: token,
                               json: try encode(payload)).stats
    }

    static func createRace(region: String, subject: String, style: String, countries: [String]? = nil, token: String) async throws -> RaceTicket {
        try await send(RaceTicket.self, path: "/v1/races", method: "POST", token: token,
                       json: try encode(RaceCreateBody(region: region, subject: subject, style: style, countries: countries)))
    }

    static func joinRace(code: String, token: String) async throws -> RaceTicket {
        try await send(RaceTicket.self, path: "/v1/races/\(code)/join", method: "POST", token: token,
                       json: try encode([String: String]()))
    }

    static func cancelRace(code: String, token: String) async throws {
        try await sendEmpty(path: "/v1/races/\(code)", method: "DELETE", token: token, json: nil)
    }

    static func inviteToRace(code: String, username: String, token: String) async throws {
        try await sendEmpty(path: "/v1/races/\(code)/invites", method: "POST", token: token,
                            json: try encode(["username": username]))
    }

    static func raceInvites(token: String) async throws -> [RaceInvite] {
        struct Box: Codable { var invites: [RaceInvite] }
        return try await send(Box.self, path: "/v1/race-invites", method: "GET", token: token, json: nil).invites
    }

    static func acceptRaceInvite(id: String, token: String) async throws -> RaceTicket {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(RaceTicket.self, path: "/v1/race-invites/\(encoded)/accept", method: "POST",
                               token: token, json: try encode([String: String]()))
    }

    static func raceResults(token: String) async throws -> [RaceHistoryItem] {
        struct Box: Codable { var results: [RaceHistoryItem] }
        return try await send(Box.self, path: "/v1/me/race-results", method: "GET", token: token, json: nil).results
    }

    static func declineRaceInvite(id: String, token: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await sendEmpty(path: "/v1/race-invites/\(encoded)/decline", method: "POST", token: token,
                            json: try encode([String: String]()))
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<Body: Encodable>(_ body: Body) throws -> Data {
        try JSONEncoder().encode(body)
    }

    private static func send<ResponseBody: Decodable>(
        _ type: ResponseBody.Type, path: String, method: String, token: String?, json: Data?
    ) async throws -> ResponseBody {
        let data = try await perform(path: path, method: method, token: token, json: json)
        do {
            return try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw APIFailure(message: "The server sent an unexpected reply")
        }
    }

    private static func sendEmpty(path: String, method: String, token: String?, json: Data?) async throws {
        _ = try await perform(path: path, method: method, token: token, json: json)
    }

    private static func perform(path: String, method: String, token: String?, json: Data?) async throws -> Data {
        var request = URLRequest(url: MapLockAPI.url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIFailure(message: message ?? "Request failed (\(status))")
        }
        return data
    }
}

private struct ErrorBody: Codable {
    var error: String
}
