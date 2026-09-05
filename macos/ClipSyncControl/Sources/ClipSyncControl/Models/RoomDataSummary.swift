import Foundation

struct RoomDataSummary: Decodable, Hashable, Identifiable, Sendable {
    let name: String
    let itemCount: Int
    let storedBytes: Int64

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case itemCount = "items"
        case storedBytes = "bytes"
    }
}

struct RoomDataListResponse: Decodable, Sendable {
    let rooms: [RoomDataSummary]
}

struct RoomDataDeleteResult: Decodable, Sendable {
    let rooms: Int
    let items: Int
    let uploads: Int
}
