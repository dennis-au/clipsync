import Darwin
import Foundation

enum ProjectValidationError: LocalizedError {
    case invalidPath
    case symlink(URL)
    case missing(URL)
    case unsafePermissions(URL)
    case unexpectedOwner(URL)
    case invalidCompose

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            "Choose an absolute ClipSync project folder."
        case .symlink:
            "The approved project files cannot be symbolic links."
        case .missing(let url):
            "Required file is missing: \(url.lastPathComponent)."
        case .unsafePermissions(let url):
            "Permissions are too open for \(url.lastPathComponent)."
        case .unexpectedOwner(let url):
            "\(url.lastPathComponent) must be owned by the signed-in macOS user."
        case .invalidCompose:
            "compose.yaml must define the clipboard and cloudflared services."
        }
    }
}

enum ProjectValidator {
    static func validate(projectPath: String) throws -> ValidatedProject {
        guard projectPath.hasPrefix("/") else {
            throw ProjectValidationError.invalidPath
        }

        let originalDirectory = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let directory = originalDirectory.resolvingSymlinksInPath()
        guard directory.path == originalDirectory.path else {
            throw ProjectValidationError.symlink(originalDirectory)
        }
        try validateDirectory(directory)

        let composeFile = directory.appendingPathComponent("compose.yaml")
        let environmentFile = directory.appendingPathComponent(".env")
        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try validateOwnedRegularFile(composeFile)
        try validateOwnedRegularFile(environmentFile)
        try validateOwnedRegularFile(dockerfile)

        let compose = try String(contentsOf: composeFile, encoding: .utf8)
        guard compose.contains("clipboard:") && compose.contains("cloudflared:") else {
            throw ProjectValidationError.invalidCompose
        }

        return ValidatedProject(
            directory: directory,
            composeFile: composeFile,
            environmentFile: environmentFile,
            fingerprint: try fingerprint(composeFile: composeFile, environmentFile: environmentFile)
        )
    }

    private static func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectValidationError.missing(url)
        }
        try validateOwnershipAndPermissions(url)
    }

    private static func validateOwnedRegularFile(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ProjectValidationError.missing(url)
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectValidationError.symlink(url)
        }
        try validateOwnershipAndPermissions(url, attributes: attributes)
    }

    private static func validateOwnershipAndPermissions(_ url: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
        let fileAttributes: [FileAttributeKey: Any]
        do {
            fileAttributes = try attributes ?? FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ProjectValidationError.missing(url)
        }

        guard let owner = fileAttributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw ProjectValidationError.unexpectedOwner(url)
        }
        guard let permissions = fileAttributes[.posixPermissions] as? NSNumber, permissions.uint16Value & 0o022 == 0 else {
            throw ProjectValidationError.unsafePermissions(url)
        }
    }

    private static func fingerprint(composeFile: URL, environmentFile: URL) throws -> ProjectFingerprint {
        let compose = try attributes(for: composeFile)
        let environment = try attributes(for: environmentFile)
        return ProjectFingerprint(
            composeModifiedAt: compose.modifiedAt,
            composeSize: compose.size,
            envModifiedAt: environment.modifiedAt,
            envSize: environment.size
        )
    }

    private static func attributes(for url: URL) throws -> (modifiedAt: TimeInterval, size: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            throw ProjectValidationError.missing(url)
        }
        return (modifiedAt.timeIntervalSince1970, size.uint64Value)
    }
}
