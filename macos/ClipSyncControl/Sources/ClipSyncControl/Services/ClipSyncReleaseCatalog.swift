import Foundation

struct ClipSyncRelease: Codable, Equatable, Identifiable {
    static let repository = "dennis-au/clipsync"
    static let defaultImage = "ghcr.io/dennis-au/clipsync:v0.3.1"

    let tagName: String
    let name: String
    let prerelease: Bool
    let draft: Bool

    var id: String { tagName }
    var image: String { "ghcr.io/dennis-au/clipsync:\(tagName)" }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case prerelease
        case draft
    }

    static func tag(fromImage image: String) -> String? {
        guard image.hasPrefix("ghcr.io/dennis-au/clipsync:"), let tag = image.split(separator: ":").last, tag.hasPrefix("v") else { return nil }
        return String(tag)
    }
}

enum ClipSyncReleaseCatalog {
    static func fetchStableReleases(session: URLSession = .shared) async throws -> [ClipSyncRelease] {
        let url = URL(string: "https://api.github.com/repos/\(ClipSyncRelease.repository)/releases?per_page=100")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipSyncControl", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ReleaseCatalogError.unavailable }
        return try JSONDecoder().decode([ClipSyncRelease].self, from: data)
            .filter { !$0.draft && !$0.prerelease && Self.isStableTag($0.tagName) }
            .sorted { Self.isHigher($0.tagName, than: $1.tagName) }
    }

    static func isStableTag(_ tag: String) -> Bool {
        tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func version(_ tag: String) -> [Int] {
        tag.dropFirst().split(separator: ".").compactMap { Int($0) }
    }

    static func isHigher(_ lhs: String, than rhs: String) -> Bool {
        let left = version(lhs)
        let right = version(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

enum ReleaseCatalogError: LocalizedError {
    case unavailable
    var errorDescription: String? { "GitHub stable releases are unavailable." }
}
