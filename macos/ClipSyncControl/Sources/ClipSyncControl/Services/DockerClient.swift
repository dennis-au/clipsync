import Darwin
import Foundation

enum DockerClientError: LocalizedError {
    case executableNotFound, invalidExecutable, daemonUnavailable, remoteContext, composeUnavailable, invalidConfiguration, invalidManagedNetwork, imageUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Docker CLI was not found. Open Docker Desktop or choose the Docker executable in Settings."
        case .invalidExecutable: "The selected Docker CLI is not an executable regular file."
        case .daemonUnavailable: "Docker Desktop is not ready."
        case .remoteContext: "ClipSync Control only works with a local Docker context."
        case .composeUnavailable: "Docker Compose v2 is not available."
        case .invalidConfiguration: "The managed ClipSync Compose configuration is invalid."
        case .invalidManagedNetwork: "The ClipSync managed Docker network is missing, not app-owned, or has no valid IPv4 subnet."
        case .imageUnavailable: "The selected ClipSync image could not be downloaded."
        }
    }
}

struct ComposeService: Decodable {
    let service: String?
    let state: String?
    let health: String?

    enum CodingKeys: String, CodingKey { case service = "Service"; case state = "State"; case health = "Health" }
}

struct DownloadedClipSyncImage: Codable, Equatable, Identifiable {
    let image: String
    let digest: String
    let downloadedAt: Date
    var id: String { "\(image)@\(digest)" }
    var tag: String { ClipSyncRelease.tag(fromImage: image) ?? image }
}

private struct DockerNetworkInspection: Decodable {
    struct IPAM: Decodable {
        struct Configuration: Decodable {
            let subnet: String?

            enum CodingKeys: String, CodingKey { case subnet = "Subnet" }
        }

        let configuration: [Configuration]?

        enum CodingKeys: String, CodingKey { case configuration = "Config" }
    }

    let name: String?
    let driver: String?
    let labels: [String: String]?
    let ipam: IPAM?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case labels = "Labels"
        case ipam = "IPAM"
    }
}

struct DockerClient {
    private let stack: ManagedStack
    private let executable: URL
    private let environmentValues: ManagedEnvironmentValues

    init(stack: ManagedStack, preferredExecutablePath: String, environmentValues: ManagedEnvironmentValues) throws {
        self.stack = stack
        executable = try Self.resolveExecutable(preferredPath: preferredExecutablePath)
        self.environmentValues = environmentValues
    }

    func validateReady() async throws {
        let daemon = try await run(["info", "--format", "{{.ServerVersion}}"])
        guard daemon.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        let composeVersion = try await run(["compose", "version", "--short"])
        guard composeVersion.exitCode == 0 else { throw DockerClientError.composeUnavailable }
        _ = try await localContext()
        _ = try await managedNetworkCIDR()
        let config = try await compose(["config", "--quiet"])
        guard config.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
    }

    func serviceStates() async throws -> [ComposeService] {
        let result = try await compose(["ps", "--all", "--format", "json"])
        guard result.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
        return Self.decodeServices(result.standardOutput)
    }

    func start(includeTunnel: Bool) async throws -> CommandResult {
        try await ensureDataVolume()
        return try await compose(Self.startStackArguments(includeTunnel: includeTunnel))
    }
    func stop() async throws -> CommandResult { try await compose(Self.stopStackArguments()) }
    func startTunnel() async throws -> CommandResult {
        try await ensureDataVolume()
        return try await compose(Self.startTunnelArguments())
    }
    func restartTunnel() async throws -> CommandResult { try await compose(Self.restartTunnelArguments()) }
    func applyPasswordChange(includeTunnel: Bool) async throws -> CommandResult {
        try await ensureDataVolume()
        return try await compose(Self.applyPasswordChangeArguments(includeTunnel: includeTunnel))
    }

    func pullSelectedImage() async throws -> CommandResult {
        let result = try await compose(["pull", "--quiet", ManagedStack.clipboardService], timeout: 180)
        guard result.exitCode == 0 else { throw DockerClientError.imageUnavailable }
        return result
    }

    func prepareMissingImages() async throws -> CommandResult {
        let result = try await compose(["pull", "--quiet", ManagedStack.clipboardService, ManagedStack.tunnelService], timeout: 180)
        guard result.exitCode == 0 else { throw DockerClientError.imageUnavailable }
        return result
    }

    /// Pull and inspect every image needed before interrupting a legacy stack.
    /// The returned digest is recorded so the migrated stack can be started offline.
    func prepareMigrationImages(includeTunnel: Bool) async throws -> String {
        let result = try await compose(Self.migrationImagePreparationArguments(includeTunnel: includeTunnel), timeout: 180)
        guard result.exitCode == 0 else { throw DockerClientError.imageUnavailable }

        let clipboardDigest = try await verifyImageDigest(environmentValues.image)
        if includeTunnel {
            _ = try await verifyImageDigest(ManagedStack.tunnelImage)
        }
        return clipboardDigest
    }

    func executeInClipboard(_ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await compose(Self.clipboardExecArguments(arguments), timeout: timeout)
    }

    func volumeExists(_ volume: String) async throws -> Bool {
        let result = try await run(["volume", "inspect", volume])
        return result.exitCode == 0
    }

    private func ensureDataVolume() async throws {
        let result = try await run(["volume", "create", ManagedStack.dataVolumeName])
        guard result.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
    }

    func discoveredLegacyProject() async throws -> ValidatedProject? {
        let result = try await run([
            "ps", "--all",
            "--filter", "label=com.docker.compose.project=clipsync",
            "--format", "{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Label \"com.docker.compose.project.config_files\"}}",
        ])
        guard result.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        for path in Self.legacyProjectPaths(from: result.standardOutput) {
            if let project = try? ProjectValidator.validate(projectPath: path) { return project }
        }
        return nil
    }

    static func legacyProjectPaths(from output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let path = line.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            return path.hasPrefix("/") ? path : nil
        })).sorted()
    }

    func downloadedClipSyncImages() async throws -> [DownloadedClipSyncImage] {
        let result = try await run(["image", "ls", "--format", "{{.Repository}}|{{.Tag}}|{{.Digest}}"])
        guard result.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        var images: [DownloadedClipSyncImage] = []
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3,
                  fields[0] == "ghcr.io/dennis-au/clipsync",
                  ClipSyncReleaseCatalog.isStableTag(fields[1]),
                  fields[2] != "<none>" else { continue }
            images.append(DownloadedClipSyncImage(image: "\(fields[0]):\(fields[1])", digest: fields[2], downloadedAt: Date()))
        }
        return images.sorted { ClipSyncReleaseCatalog.isHigher($0.tag, than: $1.tag) }
    }

    func verifyImageDigest(_ image: String) async throws -> String {
        let result = try await run(["image", "inspect", "--format", "{{index .RepoDigests 0}}", image])
        guard result.exitCode == 0 else { throw DockerClientError.imageUnavailable }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let digest = value.split(separator: "@").last, digest.hasPrefix("sha256:") else { throw DockerClientError.imageUnavailable }
        return String(digest)
    }

    func stopLegacy(project: ValidatedProject) async throws -> CommandResult {
        let context = try await localContext()
        return try await run(
            Self.legacyComposeArguments(project: project, context: context, action: ["--profile", "tunnel", "stop", "--timeout", "30"]),
            currentDirectory: project.directory,
            timeout: 45
        )
    }

    func startLegacy(project: ValidatedProject) async throws -> CommandResult {
        let context = try await localContext()
        return try await run(
            Self.legacyComposeArguments(project: project, context: context, action: ["--profile", "tunnel", "up", "-d", "--no-build"]),
            currentDirectory: project.directory,
            timeout: 90
        )
    }

    static func clipboardExecArguments(_ arguments: [String]) -> [String] { ["exec", "-T", ManagedStack.clipboardService] + arguments }
    static func startStackArguments(includeTunnel: Bool) -> [String] {
        includeTunnel ? ["--profile", "tunnel", "up", "-d", "--no-build", "--pull", "never"] : ["up", "-d", "--no-build", "--pull", "never", ManagedStack.clipboardService]
    }
    static func migrationImagePreparationArguments(includeTunnel: Bool) -> [String] {
        var arguments = ["pull", "--quiet", ManagedStack.clipboardService]
        if includeTunnel { arguments.append(ManagedStack.tunnelService) }
        return arguments
    }
    static func stopStackArguments() -> [String] { ["stop", "--timeout", "30"] }
    static func startTunnelArguments() -> [String] { ["--profile", "tunnel", "up", "-d", "--no-build", ManagedStack.tunnelService] }
    static func restartTunnelArguments() -> [String] { ["--profile", "tunnel", "restart", ManagedStack.tunnelService] }
    static func applyPasswordChangeArguments(includeTunnel: Bool) -> [String] {
        includeTunnel ? ["--profile", "tunnel", "up", "-d", "--no-build", "--pull", "never", "--force-recreate"] : ["up", "-d", "--no-build", "--pull", "never", "--force-recreate", ManagedStack.clipboardService]
    }

    static func managedNetworkCreateArguments(name: String = ManagedStack.managedNetworkName) -> [String] {
        [
            "network", "create",
            "--driver", "bridge",
            "--label", "\(ManagedStack.managedNetworkOwnershipLabel)=\(ManagedStack.managedNetworkOwnershipValue)",
            name,
        ]
    }

    static func managedNetworkInspectArguments(name: String = ManagedStack.managedNetworkName) -> [String] {
        ["network", "inspect", name, "--format", "{{json .}}"]
    }

    static func managedNetworkCIDR(from inspection: String, expectedName: String = ManagedStack.managedNetworkName) throws -> String {
        guard let data = inspection.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let network = try? JSONDecoder().decode(DockerNetworkInspection.self, from: data),
              network.name == expectedName,
              network.driver == "bridge",
              network.labels?[ManagedStack.managedNetworkOwnershipLabel] == ManagedStack.managedNetworkOwnershipValue,
              let cidr = network.ipam?.configuration?.compactMap(\.subnet).first(where: isValidIPv4CIDR) else {
            throw DockerClientError.invalidManagedNetwork
        }
        return cidr
    }

    static func composeArguments(stack: ManagedStack, environmentFile: URL, context: String, action: [String]) -> [String] {
        ["--context", context, "compose", "--project-name", ManagedStack.projectName, "--project-directory", stack.workspace.path, "--env-file", environmentFile.path, "-f", stack.composeFile.path] + action
    }

    static func legacyComposeArguments(project: ValidatedProject, context: String, action: [String]) -> [String] {
        ["--context", context, "compose", "--project-name", ManagedStack.projectName, "--project-directory", project.directory.path, "--env-file", project.environmentFile.path, "-f", project.composeFile.path] + action
    }

    private func compose(_ action: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        let context = try await localContext()
        let cidr = try await managedNetworkCIDR(context: context)
        let environmentFile = try ManagedEnvironmentFile.create(in: stack, values: environmentValues.withTrustedProxyCIDRs(cidr))
        defer { ManagedEnvironmentFile.destroy(environmentFile) }
        return try await run(Self.composeArguments(stack: stack, environmentFile: environmentFile, context: context, action: action), currentDirectory: stack.workspace, timeout: timeout)
    }

    private func managedNetworkCIDR() async throws -> String {
        try await managedNetworkCIDR(context: try await localContext())
    }

    private func managedNetworkCIDR(context: String) async throws -> String {
        let inspection = try await run(["--context", context] + Self.managedNetworkInspectArguments(name: environmentValues.managedNetworkName))
        if inspection.exitCode == 0 {
            return try Self.managedNetworkCIDR(from: inspection.standardOutput, expectedName: environmentValues.managedNetworkName)
        }

        let creation = try await run(["--context", context] + Self.managedNetworkCreateArguments(name: environmentValues.managedNetworkName))
        guard creation.exitCode == 0 else {
            let retry = try await run(["--context", context] + Self.managedNetworkInspectArguments(name: environmentValues.managedNetworkName))
            guard retry.exitCode == 0 else { throw DockerClientError.invalidManagedNetwork }
            return try Self.managedNetworkCIDR(from: retry.standardOutput, expectedName: environmentValues.managedNetworkName)
        }

        let created = try await run(["--context", context] + Self.managedNetworkInspectArguments(name: environmentValues.managedNetworkName))
        guard created.exitCode == 0 else { throw DockerClientError.invalidManagedNetwork }
        return try Self.managedNetworkCIDR(from: created.standardOutput, expectedName: environmentValues.managedNetworkName)
    }

    private func localContext() async throws -> String {
        let current = try await run(["context", "show"])
        guard current.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        let name = current.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let inspect = try await run(["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"])
        guard inspect.exitCode == 0 else { throw DockerClientError.remoteContext }
        guard inspect.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else { throw DockerClientError.remoteContext }
        return name
    }

    private func run(_ arguments: [String], currentDirectory: URL? = nil, timeout: TimeInterval = 15) async throws -> CommandResult {
        try await ProcessRunner.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory ?? stack.workspace, environment: Self.safeEnvironment, timeout: timeout)
    }

    private static var safeEnvironment: [String: String] {
        ["HOME": NSHomeDirectory(), "USER": NSUserName(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US_POSIX", "LC_ALL": "en_US_POSIX"]
    }

    private static func isValidIPv4CIDR(_ cidr: String) -> Bool {
        let pieces = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let prefix = Int(pieces[1]),
              (16...30).contains(prefix) else { return false }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            guard !octet.isEmpty, let value = Int(octet), (0...255).contains(value) else { return false }
            return String(value) == octet
        }
    }

    private static func resolveExecutable(preferredPath: String) throws -> URL {
        if !preferredPath.isEmpty { return try validateUserSelectedExecutable(preferredPath) }
        let candidates = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.docker/bin/docker"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw DockerClientError.executableNotFound }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { throw DockerClientError.invalidExecutable }
        return url
    }

    private static func validateUserSelectedExecutable(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw DockerClientError.invalidExecutable }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular, let permissions = attributes[.posixPermissions] as? NSNumber, permissions.uint16Value & 0o022 == 0, let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() || owner.uint32Value == 0 else { throw DockerClientError.invalidExecutable }
        return url
    }

    private static func decodeServices(_ output: String) -> [ComposeService] {
        let data = Data(output.utf8)
        if let array = try? JSONDecoder().decode([ComposeService].self, from: data) { return array }
        return output.split(whereSeparator: \.isNewline).compactMap { try? JSONDecoder().decode(ComposeService.self, from: Data($0.utf8)) }
    }
}
