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

struct RoomDataClient {
    static let containerBaseURL = URL(string: "http://127.0.0.1:8787")!
    static let clearAllConfirmation = "DELETE ALL CLIPSYNC DATA"
    static let destructiveRequestTimeout: TimeInterval = 5 * 60

    private let password: String
    private let docker: DockerClient

    init(project: ValidatedProject, preferredDockerPath: String, password: String) throws {
        self.password = password
        docker = try DockerClient(project: project, preferredExecutablePath: preferredDockerPath)
    }

    func listRooms() async throws -> [RoomDataSummary] {
        let data = try await send(
            path: "/admin/rooms",
            method: .get
        )
        return try Self.decodeRoomList(data).rooms.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func deleteRooms(_ names: Set<String>) async throws -> RoomDataDeleteResult {
        let roomNames = names.sorted()
        guard !roomNames.isEmpty else {
            return RoomDataDeleteResult(rooms: 0, items: 0, uploads: 0)
        }

        let body = try JSONEncoder().encode(DeleteRoomsRequest(rooms: roomNames))
        return try JSONDecoder().decode(
            RoomDataDeleteResult.self,
            from: await send(
                path: "/admin/rooms/delete",
                method: .post(body: String(decoding: body, as: UTF8.self), headers: ["Content-Type: application/json"]),
                timeout: Self.destructiveRequestTimeout
            )
        )
    }

    static func deleteRoomsArguments(password: String, roomNames: [String]) throws -> [String] {
        let body = try JSONEncoder().encode(DeleteRoomsRequest(rooms: roomNames))
        return wgetArguments(
            path: "/admin/rooms/delete",
            method: .post(body: String(decoding: body, as: UTF8.self), headers: ["Content-Type: application/json"]),
            password: password,
            timeout: destructiveRequestTimeout
        )
    }

    func clearAllData() async throws -> RoomDataDeleteResult {
        try JSONDecoder().decode(
            RoomDataDeleteResult.self,
            from: await send(
                path: "/admin/clear-all",
                method: .post(body: "", headers: ["X-Clipsync-Confirm: \(Self.clearAllConfirmation)"]),
                timeout: Self.destructiveRequestTimeout
            )
        )
    }

    static func clearAllArguments(password: String) -> [String] {
        wgetArguments(
            path: "/admin/clear-all",
            method: .post(body: "", headers: ["X-Clipsync-Confirm: \(clearAllConfirmation)"]),
            password: password,
            timeout: destructiveRequestTimeout
        )
    }

    static func listRoomsArguments(password: String) -> [String] {
        wgetArguments(path: "/admin/rooms", method: .get, password: password, timeout: 15)
    }

    static func decodeRoomList(_ data: Data) throws -> RoomDataListResponse {
        try JSONDecoder().decode(RoomDataListResponse.self, from: data)
    }

    static func passwordToken(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func send(path: String, method: Method, timeout: TimeInterval = 15) async throws -> Data {
        let arguments = Self.wgetArguments(path: path, method: method, password: password, timeout: timeout)
        let result = try await docker.executeInClipboard(arguments, timeout: timeout + 5)
        guard result.exitCode == 0 else {
            throw RoomDataClientError.requestFailed(Self.failureMessage(for: result))
        }
        return Data(result.standardOutput.utf8)
    }

    private static func wgetArguments(path: String, method: Method, password: String, timeout: TimeInterval) -> [String] {
        var arguments = [
            "wget", "-q", "-S", "-O", "-", "-T", String(Int(timeout)),
            "--header", "Cookie: clip_auth=\(passwordToken(password))",
            "--header", "Accept: application/json",
        ]
        if case let .post(body, headers) = method {
            for header in headers {
                arguments += ["--header", header]
            }
            arguments += ["--post-data", body]
        }
        arguments.append(containerBaseURL.appendingPathComponent(String(path.dropFirst())).absoluteString)
        return arguments
    }

    private static func failureMessage(for result: CommandResult) -> String {
        let details = result.standardError.lowercased()
        if details.contains("401 unauthorized") {
            return "The local ClipSync password no longer matches. Refresh approval or restart ClipSync."
        }
        if details.contains("404 not found") {
            return "This ClipSync service does not support room-data management yet."
        }
        if details.contains("is not running") || details.contains("no container found") {
            return "Start ClipSync before managing room data."
        }
        if details.contains("wget: not found") {
            return "The running ClipSync image cannot perform local room-data management."
        }
        return "ClipSync could not complete the room-data request."
    }

    private struct DeleteRoomsRequest: Encodable {
        let rooms: [String]
    }

    private enum Method {
        case get
        case post(body: String, headers: [String])
    }
}
