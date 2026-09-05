import CryptoKit
import Foundation

enum RoomDataClientError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "ClipSync returned an invalid room-data response."
        case let .requestFailed(message):
            message
        }
    }
}

struct RoomDataClient: Sendable {
    static let localBaseURL = URL(string: "http://127.0.0.1:8788")!
    static let clearAllConfirmation = "DELETE ALL CLIPSYNC DATA"
    static let destructiveRequestTimeout: TimeInterval = 5 * 60

    private let password: String
    private let session: URLSession

    init(password: String, session: URLSession = RoomDataClient.makeSession()) {
        self.password = password
        self.session = session
    }

    func listRooms() async throws -> [RoomDataSummary] {
        let request = Self.request(
            baseURL: Self.localBaseURL,
            path: "/admin/rooms",
            method: "GET",
            password: password
        )
        let data = try await send(request)
        return try Self.decodeRoomList(data).rooms.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func deleteRooms(_ names: Set<String>) async throws -> RoomDataDeleteResult {
        let roomNames = names.sorted()
        guard !roomNames.isEmpty else {
            return RoomDataDeleteResult(rooms: 0, items: 0, uploads: 0)
        }

        let request = try Self.deleteRoomsRequest(
            baseURL: Self.localBaseURL,
            password: password,
            roomNames: roomNames
        )
        return try JSONDecoder().decode(RoomDataDeleteResult.self, from: await send(request))
    }

    static func deleteRoomsRequest(baseURL: URL, password: String, roomNames: [String]) throws -> URLRequest {
        var request = Self.request(
            baseURL: baseURL,
            path: "/admin/rooms/delete",
            method: "POST",
            password: password
        )
        request.timeoutInterval = destructiveRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeleteRoomsRequest(rooms: roomNames))
        return request
    }

    func clearAllData() async throws -> RoomDataDeleteResult {
        let request = Self.clearAllRequest(baseURL: Self.localBaseURL, password: password)
        return try JSONDecoder().decode(RoomDataDeleteResult.self, from: await send(request))
    }

    static func clearAllRequest(baseURL: URL, password: String) -> URLRequest {
        var request = Self.request(
            baseURL: baseURL,
            path: "/admin/clear-all",
            method: "POST",
            password: password
        )
        request.timeoutInterval = destructiveRequestTimeout
        request.setValue(clearAllConfirmation, forHTTPHeaderField: "X-Clipsync-Confirm")
        return request
    }

    static func request(baseURL: URL, path: String, method: String, password: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("clip_auth=\(passwordToken(password))", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decodeRoomList(_ data: Data) throws -> RoomDataListResponse {
        try JSONDecoder().decode(RoomDataListResponse.self, from: data)
    }

    static func passwordToken(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RoomDataClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            switch response.statusCode {
            case 401:
                message = "The local ClipSync password no longer matches. Refresh approval or restart ClipSync."
            case 404:
                message = "This ClipSync service does not support room-data management yet."
            default:
                message = serverMessage?.isEmpty == false
                    ? serverMessage!
                    : "Room-data request failed (HTTP \(response.statusCode))."
            }
            throw RoomDataClientError.requestFailed(message)
        }
        return data
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private struct DeleteRoomsRequest: Encodable {
        let rooms: [String]
    }
}
