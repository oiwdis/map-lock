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

struct RaceTicket: Codable, Equatable {
    var code: String
    var region: String
    var seed: String
    var subject: String
    var style: String
    var webUrl: String
    var appUrl: String
}

struct FriendStatsResponse: Codable {
    var username: String
    var stats: SyncPayload
}

enum AccountClient {
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

    static func requestFriend(_ username: String, token: String) async throws {
        try await sendEmpty(path: "/v1/friends/requests", method: "POST", token: token,
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

    static func createRace(region: String, subject: String, style: String, token: String) async throws -> RaceTicket {
        try await send(RaceTicket.self, path: "/v1/races", method: "POST", token: token,
                       json: try encode(["region": region, "subject": subject, "style": style]))
    }

    static func joinRace(code: String, token: String) async throws -> RaceTicket {
        try await send(RaceTicket.self, path: "/v1/races/\(code)/join", method: "POST", token: token,
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
