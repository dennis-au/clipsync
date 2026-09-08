import Foundation

struct ManagedEnvironmentValues: Equatable {
    let image: String
    let password: String
    let tunnelToken: String?
    let managedNetworkName: String
    let trustedProxyCIDRs: String?

    init(
        image: String,
        password: String,
        tunnelToken: String?,
        managedNetworkName: String = ManagedStack.managedNetworkName,
        trustedProxyCIDRs: String? = nil
    ) {
        self.image = image
        self.password = password
        self.tunnelToken = tunnelToken
        self.managedNetworkName = managedNetworkName
        self.trustedProxyCIDRs = trustedProxyCIDRs
    }

    func withTrustedProxyCIDRs(_ cidrs: String) -> ManagedEnvironmentValues {
        ManagedEnvironmentValues(
            image: image,
            password: password,
            tunnelToken: tunnelToken,
            managedNetworkName: managedNetworkName,
            trustedProxyCIDRs: cidrs
        )
    }
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
        guard KeychainSecretStore.valid(values.managedNetworkName),
              !values.managedNetworkName.contains("\n"),
              !values.managedNetworkName.contains("\r") else {
            throw ManagedStackError.invalidEnvironmentValue
        }
        if let cidrs = values.trustedProxyCIDRs,
           (!KeychainSecretStore.valid(cidrs) || cidrs.contains("\n") || cidrs.contains("\r")) {
            throw ManagedStackError.invalidEnvironmentValue
        }
        let file = stack.runtimeDirectory.appendingPathComponent("compose-env-\(UUID().uuidString).env")
        var lines = [
            "CLIPSYNC_IMAGE=\(values.image)",
            "CLIPSYNC_PASSWORD=\(values.password)",
            "CLIPSYNC_MANAGED_NETWORK=\(values.managedNetworkName)",
        ]
        if let cidrs = values.trustedProxyCIDRs { lines.append("CLIPSYNC_TRUSTED_PROXY_CIDRS=\(cidrs)") }
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
