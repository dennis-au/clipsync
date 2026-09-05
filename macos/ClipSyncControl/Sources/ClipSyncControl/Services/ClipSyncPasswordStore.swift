import Foundation
import Security

enum ClipSyncPasswordStoreError: LocalizedError {
    case passwordMissing
    case passwordFormatUnsupported
    case environmentUnreadable
    case environmentWriteFailed
    case clipboardWriteFailed
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .passwordMissing:
            "CLIPSYNC_PASSWORD is not configured in .env."
        case .passwordFormatUnsupported:
            "CLIPSYNC_PASSWORD uses an unsupported .env format."
        case .environmentUnreadable:
            "ClipSync Control could not read .env."
        case .environmentWriteFailed:
            "ClipSync Control could not update .env."
        case .clipboardWriteFailed:
            "ClipSync Control could not copy the password to the clipboard."
        case .randomGenerationFailed:
            "ClipSync Control could not generate a new password."
        }
    }
}

enum ClipSyncPasswordStore {
    private static let passwordLineExpression = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*(?:export[ \t]+)?CLIPSYNC_PASSWORD[ \t]*=[ \t]*)([^\r\n]*)$"#
    )

    static func currentPassword(in project: ValidatedProject) throws -> String {
        let contents = try environmentContents(in: project)
        let match = try passwordMatch(in: contents)
        let rawValue = (contents as NSString).substring(with: match.range(at: 2))
        return try normalizedPassword(from: rawValue)
    }

    static func generatePassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw ClipSyncPasswordStoreError.randomGenerationFailed
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func replacePassword(in project: ValidatedProject, with password: String) throws {
        guard password.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ClipSyncPasswordStoreError.passwordFormatUnsupported
        }

        let contents = try environmentContents(in: project)
        let match = try passwordMatch(in: contents)
        let updated = (contents as NSString).replacingCharacters(in: match.range(at: 2), with: password)
        try writeAtomically(updated, to: project.environmentFile)
    }

    private static func environmentContents(in project: ValidatedProject) throws -> String {
        do {
            return try String(contentsOf: project.environmentFile, encoding: .utf8)
        } catch {
            throw ClipSyncPasswordStoreError.environmentUnreadable
        }
    }

    private static func passwordMatch(in contents: String) throws -> NSTextCheckingResult {
        let range = NSRange(contents.startIndex..., in: contents)
        guard let match = passwordLineExpression.matches(in: contents, range: range).last else {
            throw ClipSyncPasswordStoreError.passwordMissing
        }
        return match
    }

    private static func normalizedPassword(from rawValue: String) throws -> String {
        var password = rawValue.trimmingCharacters(in: .whitespaces)
        if password.first == "\"", password.last == "\"", password.count >= 2 {
            password.removeFirst()
            password.removeLast()
        } else if password.first == "'", password.last == "'", password.count >= 2 {
            password.removeFirst()
            password.removeLast()
        } else if let commentStart = password.range(of: " #") {
            password = String(password[..<commentStart.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        guard !password.isEmpty else {
            throw ClipSyncPasswordStoreError.passwordMissing
        }
        guard !password.contains("$") else {
            throw ClipSyncPasswordStoreError.passwordFormatUnsupported
        }
        return password
    }

    private static func writeAtomically(_ contents: String, to environmentFile: URL) throws {
        let fileManager = FileManager.default
        let temporaryFile = environmentFile
            .deletingLastPathComponent()
            .appendingPathComponent(".clipsync-control-\(UUID().uuidString).tmp")
        let data = Data(contents.utf8)

        guard fileManager.createFile(
            atPath: temporaryFile.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw ClipSyncPasswordStoreError.environmentWriteFailed
        }

        do {
            _ = try fileManager.replaceItemAt(environmentFile, withItemAt: temporaryFile)
        } catch {
            try? fileManager.removeItem(at: temporaryFile)
            throw ClipSyncPasswordStoreError.environmentWriteFailed
        }
    }
}
