import Darwin
import Foundation

enum DockerClientError: LocalizedError, Equatable {
    case executableNotFound, invalidExecutable, daemonUnavailable, remoteContext, composeUnavailable, invalidConfiguration, invalidManagedNetwork, imageUnavailable
    case invalidContainerInspection
    case sharedVolumeConflict(String)
    case previousManagedAdoptionFailed
    case managedFailClosedStopFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Docker CLI was not found. Open Docker Desktop or choose the Docker executable in Settings."
        case .invalidExecutable: "The selected Docker CLI is not an executable regular file."
        case .daemonUnavailable: "Docker Desktop is not ready."
        case .remoteContext: "ClipSync Control only works with a local Docker context."
        case .composeUnavailable: "Docker Compose v2 is not available."
        case .invalidConfiguration: "The managed ClipSync Compose configuration is invalid."
        case .invalidManagedNetwork: "The ClipSync managed Docker network is missing, not app-owned, or has no valid IPv4 subnet."
        case .imageUnavailable: "A required ClipSync or Cloudflare image is not downloaded."
        case .invalidContainerInspection: "Docker returned invalid container ownership information. ClipSync was not started."
        case let .sharedVolumeConflict(name): "ClipSync data is already in use by container \(name). The controller left that container unchanged."
        case .previousManagedAdoptionFailed: "The previous controller-managed containers could not be adopted safely. ClipSync was not started."
        case .managedFailClosedStopFailed: "A ClipSync data ownership conflict was detected, but the controller could not stop all of its managed services."
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

struct LegacyProjectReference: Equatable {
    let directory: String
    let composeFiles: [String]
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
    static let gracefulStopTimeout: TimeInterval = 45
    static let legacyServiceNames = ["clipboard", "cloudflared"]

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
        try await ensureRequiredImagesAvailable(includeTunnel: includeTunnel)
        try await ensureDataVolume()
        try await prepareForManagedStart()
        return try await performStartAttempt {
            try await compose(Self.startStackArguments(includeTunnel: includeTunnel))
        }
    }
    func stop() async throws -> CommandResult { try await compose(Self.stopStackArguments(), timeout: Self.gracefulStopTimeout) }
    func forceStop() async throws -> CommandResult { try await compose(Self.forceStopStackArguments()) }
    func startTunnel() async throws -> CommandResult {
        try await ensureRequiredImagesAvailable(includeTunnel: true)
        try await ensureDataVolume()
        try await prepareForManagedStart()
        return try await performStartAttempt { try await compose(Self.startTunnelArguments()) }
    }
    func restartTunnel() async throws -> CommandResult {
        try await ensureRequiredImagesAvailable(includeTunnel: true)
        try await prepareForManagedStart()
        return try await performStartAttempt { try await compose(Self.restartTunnelArguments()) }
    }
    func applyPasswordChange(includeTunnel: Bool) async throws -> CommandResult {
        try await ensureRequiredImagesAvailable(includeTunnel: includeTunnel)
        try await ensureDataVolume()
        try await prepareForManagedStart()
        return try await performStartAttempt {
            try await compose(Self.applyPasswordChangeArguments(includeTunnel: includeTunnel))
        }
    }

    func prepareForManagedStart() async throws {
        var audit = try await sharedVolumeOwnershipAudit()
        switch ContainerOwnership.startDecision(for: audit) {
        case .allow, .adoptPrevious:
            break
        case let .refuse(name):
            throw DockerClientError.sharedVolumeConflict(name)
        case let .failClosed(name):
            try await failClosedIfManagedIsRunning(audit: audit)
            throw DockerClientError.sharedVolumeConflict(name)
        }

        try await adoptPreviousManagedContainers()
        audit = try await sharedVolumeOwnershipAudit()

        switch ContainerOwnership.startDecision(for: audit) {
        case .allow:
            return
        case .adoptPrevious:
            throw DockerClientError.previousManagedAdoptionFailed
        case let .refuse(name):
            throw DockerClientError.sharedVolumeConflict(name)
        case let .failClosed(name):
            try await failClosedIfManagedIsRunning(audit: audit)
            throw DockerClientError.sharedVolumeConflict(name)
        }
    }

    func enforceRuntimeOwnership() async throws {
        let audit = try await sharedVolumeOwnershipAudit()
        switch ContainerOwnership.runtimeDecision(for: audit) {
        case .allow, .adoptPrevious:
            return
        case let .refuse(name):
            throw DockerClientError.sharedVolumeConflict(name)
        case let .failClosed(name):
            try await failClosedIfManagedIsRunning(audit: audit)
            throw DockerClientError.sharedVolumeConflict(name)
        }
    }

    func ensureVolumeUnownedForLegacyRollback() async throws {
        try await adoptPreviousManagedContainers()
        let audit = try await sharedVolumeOwnershipAudit()
        guard audit.owners.isEmpty else {
            let container = audit.foreign.first
                ?? audit.currentManaged.first
                ?? audit.upgradeCompatible.first
            throw DockerClientError.sharedVolumeConflict(container?.displayName ?? ManagedStack.dataVolumeName)
        }
    }

    func selectedImageAvailable() async throws -> Bool {
        try await imageAvailable(environmentValues.image)
    }

    func requiredImagesAvailable(includeTunnel: Bool) async throws -> Bool {
        for image in Self.requiredImageReferences(clipboardImage: environmentValues.image, includeTunnel: includeTunnel) {
            guard try await imageAvailable(image) else { return false }
        }
        return true
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

    private func ensureRequiredImagesAvailable(includeTunnel: Bool) async throws {
        guard try await requiredImagesAvailable(includeTunnel: includeTunnel) else { throw DockerClientError.imageUnavailable }
    }

    private func imageAvailable(_ image: String) async throws -> Bool {
        let result = try await run(["image", "inspect", image])
        return result.exitCode == 0
    }

    func discoveredLegacyProject() async throws -> ValidatedProject? {
        let result = try await run([
            "ps", "--all",
            "--filter", "label=com.docker.compose.project=clipsync",
            "--format", "{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Label \"com.docker.compose.project.config_files\"}}",
        ])
        guard result.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        for reference in Self.legacyProjectReferences(from: result.standardOutput) {
            if let project = try? ProjectValidator.validate(
                projectPath: reference.directory,
                configFilePaths: reference.composeFiles
            ) { return project }
        }
        return nil
    }

    static func legacyProjectReferences(from output: String) -> [LegacyProjectReference] {
        var references: [LegacyProjectReference] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[0].hasPrefix("/") else { continue }
            let composeFiles = ContainerOwnership.composePaths(from: fields[1])
            guard !composeFiles.isEmpty else { continue }
            let key = fields[0] + "|" + composeFiles.joined(separator: ",")
            guard seen.insert(key).inserted else { continue }
            references.append(.init(directory: fields[0], composeFiles: composeFiles))
        }
        return references.sorted { lhs, rhs in
            lhs.directory == rhs.directory
                ? lhs.composeFiles.joined(separator: ",") < rhs.composeFiles.joined(separator: ",")
                : lhs.directory < rhs.directory
        }
    }

    static func legacyProjectPaths(from output: String) -> [String] {
        Array(Set(legacyProjectReferences(from: output).map(\.directory))).sorted()
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
            Self.legacyComposeArguments(project: project, context: context, action: Self.stopLegacyArguments()),
            currentDirectory: project.directory,
            timeout: 45
        )
    }

    func forceStopLegacy(project: ValidatedProject) async throws -> CommandResult {
        let context = try await localContext()
        return try await run(
            Self.legacyComposeArguments(project: project, context: context, action: Self.forceStopLegacyArguments()),
            currentDirectory: project.directory
        )
    }

    func legacyServiceStates(project: ValidatedProject) async throws -> [ComposeService] {
        let context = try await localContext()
        let result = try await run(
            Self.legacyComposeArguments(project: project, context: context, action: ["ps", "--all", "--format", "json"]),
            currentDirectory: project.directory
        )
        guard result.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        return Self.decodeServices(result.standardOutput)
    }

    func startLegacy(project: ValidatedProject) async throws -> CommandResult {
        let context = try await localContext()
        return try await run(
            Self.legacyComposeArguments(project: project, context: context, action: Self.startLegacyArguments()),
            currentDirectory: project.directory,
            timeout: 90
        )
    }

    static func clipboardExecArguments(_ arguments: [String]) -> [String] { ["exec", "-T", ManagedStack.clipboardService] + arguments }
    static func startStackArguments(includeTunnel: Bool) -> [String] {
        includeTunnel ? ["--profile", "tunnel", "up", "-d", "--no-build", "--pull", "never"] : ["up", "-d", "--no-build", "--pull", "never", ManagedStack.clipboardService]
    }
    static func requiredImageReferences(clipboardImage: String, includeTunnel: Bool) -> [String] {
        includeTunnel ? [clipboardImage, ManagedStack.tunnelImage] : [clipboardImage]
    }
    static func migrationImagePreparationArguments(includeTunnel: Bool) -> [String] {
        var arguments = ["pull", "--quiet", ManagedStack.clipboardService]
        if includeTunnel { arguments.append(ManagedStack.tunnelService) }
        return arguments
    }
    static func stopStackArguments() -> [String] {
        ["--profile", "tunnel", "stop", "--timeout", "30"] + ManagedStack.managedServiceNames
    }
    static func forceStopStackArguments() -> [String] {
        ["--profile", "tunnel", "kill", "--signal", "SIGKILL"] + ManagedStack.managedServiceNames
    }
    static func stopLegacyArguments() -> [String] {
        ["--profile", "tunnel", "stop", "--timeout", "30"] + legacyServiceNames
    }
    static func forceStopLegacyArguments() -> [String] {
        ["--profile", "tunnel", "kill", "--signal", "SIGKILL"] + legacyServiceNames
    }
    static func startLegacyArguments() -> [String] {
        ["--profile", "tunnel", "up", "-d", "--no-build"] + legacyServiceNames
    }
    static func startTunnelArguments() -> [String] { ["--profile", "tunnel", "up", "-d", "--no-build", ManagedStack.tunnelService] }
    static func restartTunnelArguments() -> [String] {
        ["--profile", "tunnel", "up", "-d", "--no-build", "--pull", "never", "--force-recreate", ManagedStack.tunnelService]
    }
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
        var arguments = ["--context", context, "compose", "--project-name", ManagedStack.previousProjectName, "--project-directory", project.directory.path, "--env-file", project.environmentFile.path]
        for composeFile in project.composeFiles {
            arguments += ["-f", composeFile.path]
        }
        return arguments + action
    }

    static func runningVolumeContainerIDsArguments(volumeName: String = ManagedStack.dataVolumeName) -> [String] {
        ["container", "ls", "--filter", "volume=\(volumeName)", "--format", "{{.ID}}"]
    }

    static func inspectContainerArguments(ids: [String]) -> [String] {
        ["container", "inspect"] + ids
    }

    static func previousManagedContainerIDsArguments() -> [String] {
        ["container", "ls", "--all", "--filter", "label=com.docker.compose.project=\(ManagedStack.previousProjectName)", "--format", "{{.ID}}"]
    }

    static func ownedManagedContainerIDsArguments() -> [String] {
        ["container", "ls", "--filter", "label=\(ManagedStack.ownershipLabel)=\(ManagedStack.ownershipValue)", "--format", "{{.ID}}"]
    }

    static func stopContainerArguments(id: String, timeout: Int = 30) -> [String] {
        ["container", "stop", "--time", String(timeout), id]
    }

    static func killContainerArguments(id: String) -> [String] {
        ["container", "kill", "--signal", "SIGKILL", id]
    }

    static func removeContainerArguments(id: String) -> [String] {
        ["container", "rm", id]
    }

    static func attemptAllOwnedStops(
        _ containers: [DockerContainerInspection],
        stop: (DockerContainerInspection) async throws -> Void
    ) async -> Bool {
        let ordered = containers.sorted { managedStopPriority($0) < managedStopPriority($1) }
        var succeeded = true
        for container in ordered where container.state.running {
            do {
                try await stop(container)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    static func performStartAttempt(
        action: () async throws -> CommandResult,
        postAttempt: (Bool) async throws -> Void
    ) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await action()
        } catch {
            let originalError = error
            do {
                try await postAttempt(false)
            } catch {
                throw error
            }
            throw originalError
        }
        try await postAttempt(result.exitCode == 0)
        return result
    }

    private func sharedVolumeOwnershipAudit() async throws -> ContainerOwnershipAudit {
        let containers = try await containers(matching: Self.runningVolumeContainerIDsArguments())
        return ContainerOwnership.audit(containers, stack: stack)
    }

    private func verifyManagedOwnershipAfterStart() async throws {
        let audit = try await sharedVolumeOwnershipAudit()
        switch ContainerOwnership.postStartDecision(for: audit) {
        case .allow:
            return
        case let .failClosed(name), let .refuse(name):
            try await stopOwnedManagedServices()
            throw DockerClientError.sharedVolumeConflict(name)
        case .adoptPrevious:
            try await stopOwnedManagedServices()
            throw DockerClientError.previousManagedAdoptionFailed
        }
    }

    private func performStartAttempt(
        action: () async throws -> CommandResult
    ) async throws -> CommandResult {
        try await Self.performStartAttempt(action: action) { succeeded in
            if succeeded {
                try await verifyManagedOwnershipAfterStart()
            } else {
                try await stopOwnedManagedServices()
                try await enforceRuntimeOwnership()
            }
        }
    }

    private func adoptPreviousManagedContainers() async throws {
        let candidates = try await containers(matching: Self.previousManagedContainerIDsArguments())
        let compatible = candidates.filter {
            ContainerOwnership.isUpgradeCompatibleService($0, stack: stack, service: "managed-clipboard")
                || ContainerOwnership.isUpgradeCompatibleService($0, stack: stack, service: "managed-cloudflared")
        }
        guard !compatible.isEmpty else { return }

        let ordered = compatible.sorted { adoptionPriority($0) < adoptionPriority($1) }
        for container in ordered {
            try await stopExactContainer(container, timeout: 30)
            let removal = try await run(Self.removeContainerArguments(id: container.id))
            guard removal.exitCode == 0 else { throw DockerClientError.previousManagedAdoptionFailed }
        }
    }

    private func failClosedIfManagedIsRunning(audit: ContainerOwnershipAudit) async throws {
        guard !audit.currentManaged.isEmpty else { return }
        try await stopOwnedManagedServices()
    }

    private func stopOwnedManagedServices() async throws {
        let candidates = try await containers(matching: Self.ownedManagedContainerIDsArguments())
        let owned = candidates.filter {
            ContainerOwnership.isCurrentManagedService($0, stack: stack, role: "tunnel", service: ManagedStack.tunnelService)
                || ContainerOwnership.isCurrentManagedService($0, stack: stack, role: "clipboard", service: ManagedStack.clipboardService)
        }
        let allStopsSucceeded = await Self.attemptAllOwnedStops(owned) { container in
            try await stopExactContainer(container, timeout: 10)
        }
        do {
            let remaining = try await containers(matching: Self.ownedManagedContainerIDsArguments())
            guard allStopsSucceeded, !remaining.contains(where: {
                ContainerOwnership.isCurrentManagedService($0, stack: stack, role: "tunnel", service: ManagedStack.tunnelService)
                    || ContainerOwnership.isCurrentManagedService($0, stack: stack, role: "clipboard", service: ManagedStack.clipboardService)
            }) else {
                throw DockerClientError.managedFailClosedStopFailed
            }
        } catch {
            throw DockerClientError.managedFailClosedStopFailed
        }
    }

    private func stopExactContainer(_ container: DockerContainerInspection, timeout: Int) async throws {
        guard container.state.running else { return }
        do {
            _ = try await run(
                Self.stopContainerArguments(id: container.id, timeout: timeout),
                timeout: TimeInterval(timeout + 5)
            )
            if !(try await containerIsRunning(id: container.id)) { return }
        } catch ProcessRunnerError.timedOut {
            // Fall through to an exact-ID kill after Docker misses the graceful deadline.
        }
        let kill = try await run(Self.killContainerArguments(id: container.id))
        guard kill.exitCode == 0, !(try await containerIsRunning(id: container.id)) else {
            throw DockerClientError.managedFailClosedStopFailed
        }
    }

    private func containerIsRunning(id: String) async throws -> Bool {
        let result = try await run(["container", "inspect", "--format", "{{.State.Running}}", id])
        if result.exitCode != 0 { return false }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func containers(matching listArguments: [String]) async throws -> [DockerContainerInspection] {
        let listing = try await run(listArguments)
        guard listing.exitCode == 0 else { throw DockerClientError.daemonUnavailable }
        let ids = listing.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return [] }
        let inspection = try await run(Self.inspectContainerArguments(ids: ids))
        guard inspection.exitCode == 0 else { throw DockerClientError.invalidContainerInspection }
        return try ContainerOwnership.decodeInspections(inspection.standardOutput)
    }

    private func adoptionPriority(_ container: DockerContainerInspection) -> Int {
        container.labels["com.docker.compose.service"] == "managed-cloudflared" ? 0 : 1
    }

    private static func managedStopPriority(_ container: DockerContainerInspection) -> Int {
        container.labels[ManagedStack.roleLabel] == "tunnel" ? 0 : 1
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
