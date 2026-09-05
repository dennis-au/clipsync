import Darwin
import Foundation

enum DockerClientError: LocalizedError {
    case executableNotFound
    case invalidExecutable
    case daemonUnavailable
    case remoteContext
    case composeUnavailable
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Docker CLI was not found. Open Docker Desktop or choose the Docker executable in Settings."
        case .invalidExecutable: "The selected Docker CLI is not an executable regular file."
        case .daemonUnavailable: "Docker Desktop is not ready."
        case .remoteContext: "ClipSync Control only works with a local Docker context."
        case .composeUnavailable: "Docker Compose v2 is not available."
        case .invalidConfiguration: "ClipSync Compose configuration is invalid."
        }
    }
}

struct ComposeService: Decodable {
    let service: String?
    let state: String?
    let health: String?

    enum CodingKeys: String, CodingKey {
        case service = "Service"
        case state = "State"
        case health = "Health"
    }
}

struct DockerClient {
    private let project: ValidatedProject
    private let executable: URL

    init(project: ValidatedProject, preferredExecutablePath: String) throws {
        self.project = project
        executable = try Self.resolveExecutable(preferredPath: preferredExecutablePath)
    }

    func validateReady() async throws {
        let daemon = try await run(["info", "--format", "{{.ServerVersion}}"])
        guard daemon.exitCode == 0 else {
            throw DockerClientError.daemonUnavailable
        }

        let composeVersion = try await run(["compose", "version", "--short"])
        guard composeVersion.exitCode == 0 else {
            throw DockerClientError.composeUnavailable
        }

        _ = try await localContext()
        let config = try await compose(["config", "--quiet"])
        guard config.exitCode == 0 else {
            throw DockerClientError.invalidConfiguration
        }
    }

    func serviceStates() async throws -> [ComposeService] {
        let result = try await compose(["ps", "--all", "--format", "json"])
        guard result.exitCode == 0 else {
            throw DockerClientError.invalidConfiguration
        }
        return Self.decodeServices(result.standardOutput)
    }

    func start() async throws -> CommandResult {
        try await compose(["--profile", "tunnel", "up", "-d", "--no-build"])
    }

    func stop() async throws -> CommandResult {
        try await compose(["--profile", "tunnel", "stop", "--timeout", "30"])
    }

    func applyPasswordChange() async throws -> CommandResult {
        try await compose(["--profile", "tunnel", "up", "-d", "--no-build", "--force-recreate"])
    }

    func prepareMissingImages() async throws -> CommandResult {
        let clipboardMissing = try await !imageExists("denlab-clipboard:local")
        let tunnelMissing = try await !imageExists("cloudflare/cloudflared:2026.8.2")

        if clipboardMissing {
            let build = try await compose(["build", "--quiet", "clipboard"], timeout: 120)
            guard build.exitCode == 0 else { return build }
        }
        if tunnelMissing {
            let pull = try await compose(["pull", "--quiet", "cloudflared"], timeout: 120)
            guard pull.exitCode == 0 else { return pull }
        }
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    static func composeArguments(project: ValidatedProject, context: String, action: [String]) -> [String] {
        [
            "--context", context,
            "compose",
            "--project-directory", project.directory.path,
            "--env-file", project.environmentFile.path,
            "-f", project.composeFile.path,
        ] + action
    }

    private func compose(_ action: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        let context = try await localContext()
        return try await run(Self.composeArguments(project: project, context: context, action: action), timeout: timeout)
    }

    private func imageExists(_ image: String) async throws -> Bool {
        let result = try await run(["image", "inspect", image])
        return result.exitCode == 0
    }

    private func localContext() async throws -> String {
        let current = try await run(["context", "show"])
        guard current.exitCode == 0 else {
            throw DockerClientError.daemonUnavailable
        }
        let name = current.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let inspect = try await run(["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"])
        guard inspect.exitCode == 0 else {
            throw DockerClientError.remoteContext
        }
        let host = inspect.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.hasPrefix("unix://") else {
            throw DockerClientError.remoteContext
        }
        return name
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 15) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: project.directory,
            environment: Self.safeEnvironment,
            timeout: timeout
        )
    }

    private static var safeEnvironment: [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "LANG": "en_US_POSIX",
            "LC_ALL": "en_US_POSIX",
        ]
    }

    private static func resolveExecutable(preferredPath: String) throws -> URL {
        if !preferredPath.isEmpty {
            return try validateUserSelectedExecutable(preferredPath)
        }

        let candidates = [
                "/Applications/Docker.app/Contents/Resources/bin/docker",
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                NSHomeDirectory() + "/.docker/bin/docker",
            ]

        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DockerClientError.executableNotFound
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw DockerClientError.invalidExecutable
        }
        return url
    }

    private static func validateUserSelectedExecutable(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw DockerClientError.invalidExecutable
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.uint16Value & 0o022 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() || owner.uint32Value == 0 else {
            throw DockerClientError.invalidExecutable
        }
        return url
    }

    private static func decodeServices(_ output: String) -> [ComposeService] {
        let data = Data(output.utf8)
        if let array = try? JSONDecoder().decode([ComposeService].self, from: data) {
            return array
        }
        return output.split(whereSeparator: \ .isNewline).compactMap { line in
            try? JSONDecoder().decode(ComposeService.self, from: Data(line.utf8))
        }
    }
}
