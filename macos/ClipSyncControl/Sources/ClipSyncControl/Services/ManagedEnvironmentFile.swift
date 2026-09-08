import Foundation

struct ManagedEnvironmentValues: Equatable {
    let image: String
    let password: String
    let tunnelToken: String?
}

enum ManagedEnvironmentFile {
    static func create(in stack: ManagedStack, values: ManagedEnvironmentValues, fileManager: FileManager = .default) throws -> URL {
        guard KeychainSecretStore.valid(values.password) else { throw ManagedStackError.secretMissing }
        guard !values.image.isEmpty, !values.image.contains("\n"), !values.image.contains("\r") else {
            throw ManagedStackError.invalidEnvironmentValue
        }
        if let token = values.tunnelToken, !KeychainSecretStore.valid(token) {
            throw ManagedStackError.invalidEnvironmentValue
        }
        let file = stack.runtimeDirectory.appendingPathComponent("compose-env-\(UUID().uuidString).env")
        var lines = ["CLIPSYNC_IMAGE=\(values.image)", "CLIPSYNC_PASSWORD=\(values.password)"]
        if let token = values.tunnelToken { lines.append("CLOUDFLARE_TUNNEL_TOKEN=\(token)") }
        guard fileManager.createFile(atPath: file.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw ManagedStackError.invalidEnvironmentValue
        }
        return file
    }

    static func destroy(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }

    static func redactedDescription(_ arguments: [String], secrets: [String]) -> String {
        arguments.map { argument in
            secrets.reduce(argument) { partial, secret in
                secret.isEmpty ? partial : partial.replacingOccurrences(of: secret, with: "[REDACTED]")
            }
        }.joined(separator: " ")
    }
}
