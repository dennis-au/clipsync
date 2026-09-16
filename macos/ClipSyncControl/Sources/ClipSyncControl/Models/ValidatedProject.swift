import Foundation

struct ProjectFingerprint: Codable, Equatable {
    let composeModifiedAt: TimeInterval
    let composeSize: UInt64
    let envModifiedAt: TimeInterval
    let envSize: UInt64
}

struct ProjectApproval: Codable, Equatable {
    let path: String
    let fingerprint: ProjectFingerprint
    let approvedAt: Date
}

struct ValidatedProject {
    let directory: URL
    let composeFiles: [URL]
    let environmentFile: URL
    let fingerprint: ProjectFingerprint

    var composeFile: URL { composeFiles[0] }
}
