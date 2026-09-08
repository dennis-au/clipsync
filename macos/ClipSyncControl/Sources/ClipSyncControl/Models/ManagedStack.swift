import Foundation

struct ManagedStack: Equatable {
    static let projectName = "clipsync"
    static let dataVolumeName = "clipsync_clipboard-data"
    static let clipboardService = "managed-clipboard"
    static let tunnelService = "managed-cloudflared"
    static let tunnelImage = "cloudflare/cloudflared:2026.8.2@sha256:0aa26e284f05e6c77ae375b8c9c11d9eb6a448fb7bcd8d40f31cb6176189eb38"

    let workspace: URL
    let composeFile: URL
    let runtimeDirectory: URL

    init(workspace: URL? = nil) {
        let base = workspace ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipSync", isDirectory: true)
        self.workspace = base
        composeFile = base.appendingPathComponent("managed-compose.yaml")
        runtimeDirectory = base.appendingPathComponent("runtime", isDirectory: true)
    }

    func prepare(fileManager: FileManager = .default, resourceBundle: Bundle = .module) throws {
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: workspace.path)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: runtimeDirectory.path)
        guard let source = resourceBundle.url(forResource: "managed-compose", withExtension: "yaml") else {
            throw ManagedStackError.resourceMissing
        }
        let bundledContents = try Data(contentsOf: source)
        let installedContents = try? Data(contentsOf: composeFile)
        if installedContents != bundledContents {
            try bundledContents.write(to: composeFile, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: composeFile.path)
        }
        try scrubTemporaryEnvironmentFiles(fileManager: fileManager)
    }

    func scrubTemporaryEnvironmentFiles(fileManager: FileManager = .default) throws {
        guard let entries = try? fileManager.contentsOfDirectory(at: runtimeDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("compose-env-") && entry.pathExtension == "env" {
            try? fileManager.removeItem(at: entry)
        }
    }
}

enum ManagedStackError: LocalizedError {
    case resourceMissing
    case secretMissing
    case invalidEnvironmentValue

    var errorDescription: String? {
        switch self {
        case .resourceMissing: "The bundled ClipSync Compose configuration is missing."
        case .secretMissing: "Set a ClipSync password before starting the managed stack."
        case .invalidEnvironmentValue: "A ClipSync setting contains an unsupported newline."
        }
    }
}
