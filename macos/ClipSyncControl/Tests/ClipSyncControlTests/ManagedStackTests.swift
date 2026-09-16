import Foundation
import XCTest
@testable import ClipSyncControl

final class ManagedStackTests: XCTestCase {
    func testManagedComposeUsesExternalDataVolumeAndPinnedTunnel() throws {
        let stack = try preparedStack()
        let compose = try String(contentsOf: stack.composeFile, encoding: .utf8)

        XCTAssertTrue(compose.contains("  clipboard:"))
        XCTAssertTrue(compose.contains("  cloudflared:"))
        XCTAssertTrue(compose.contains("io.clipsync.control.owner: ClipSyncControl"))
        XCTAssertTrue(compose.contains("io.clipsync.control.role: clipboard"))
        XCTAssertTrue(compose.contains("io.clipsync.control.role: tunnel"))
        XCTAssertTrue(compose.contains("external: true"))
        XCTAssertTrue(compose.contains("name: clipsync_clipboard-data"))
        XCTAssertTrue(compose.contains("127.0.0.1:8788:8787"))
        XCTAssertTrue(compose.contains("aliases: [clipboard]"))
        XCTAssertTrue(compose.contains("managed-net:"))
        XCTAssertTrue(compose.contains("external: true"))
        XCTAssertTrue(compose.contains("name: ${CLIPSYNC_MANAGED_NETWORK:?Managed network is required.}"))
        XCTAssertTrue(compose.contains("cloudflare/cloudflared:2026.8.2@sha256:"))
        XCTAssertTrue(compose.contains("CLIPSYNC_TRUSTED_PROXY_CIDRS: ${CLIPSYNC_TRUSTED_PROXY_CIDRS:?Managed network CIDR is required.}"))
        XCTAssertFalse(compose.contains("ipam:"))
        XCTAssertFalse(compose.contains("ipv4_address:"))
        XCTAssertFalse(compose.contains("172.31."))
        XCTAssertFalse(compose.contains("driver: bridge"))
        XCTAssertFalse(compose.contains("container_name:"))
        XCTAssertFalse(compose.contains("build:"))
    }

    func testTemporaryEnvironmentIsPrivateAndRemoved() throws {
        let stack = try preparedStack()
        let secret = "very-secret-value"
        let file = try ManagedEnvironmentFile.create(
            in: stack,
            values: ManagedEnvironmentValues(
                image: "ghcr.io/dennis-au/clipsync:v0.3.0",
                password: secret,
                tunnelToken: "token-value",
                trustedProxyCIDRs: "192.168.80.0/20"
            )
        )
        defer { ManagedEnvironmentFile.destroy(file) }

        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value, 0o600)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains("CLIPSYNC_PASSWORD=\(secret)"))
        XCTAssertTrue(contents.contains("CLIPSYNC_MANAGED_NETWORK=\(ManagedStack.managedNetworkName)"))
        XCTAssertTrue(contents.contains("CLIPSYNC_TRUSTED_PROXY_CIDRS=192.168.80.0/20"))
        XCTAssertEqual(ManagedEnvironmentFile.redactedDescription(["docker", secret], secrets: [secret]), "docker [REDACTED]")

        ManagedEnvironmentFile.destroy(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testManagedDockerCommandsCannotDestroyPersistentData() throws {
        let stack = try preparedStack()
        let environment = try ManagedEnvironmentFile.create(
            in: stack,
            values: ManagedEnvironmentValues(image: "ghcr.io/dennis-au/clipsync:v0.3.0", password: "test-password", tunnelToken: nil)
        )
        defer { ManagedEnvironmentFile.destroy(environment) }

        let actions = [
            DockerClient.startStackArguments(includeTunnel: false),
            DockerClient.stopStackArguments(),
            DockerClient.forceStopStackArguments(),
            DockerClient.applyPasswordChangeArguments(includeTunnel: true),
            DockerClient.composeArguments(stack: stack, environmentFile: environment, context: "desktop-linux", action: ["config", "--quiet"]),
        ]
        for arguments in actions {
            XCTAssertFalse(arguments.contains("down"))
            XCTAssertFalse(arguments.contains("-v"))
            XCTAssertFalse(arguments.contains("rm"))
            XCTAssertFalse(arguments.contains("prune"))
            XCTAssertTrue(arguments.joined(separator: " ").contains("--project-name clipsync-managed") || arguments == DockerClient.stopStackArguments() || arguments == DockerClient.forceStopStackArguments() || arguments == DockerClient.startStackArguments(includeTunnel: false) || arguments == DockerClient.applyPasswordChangeArguments(includeTunnel: true))
        }
    }

    func testStopCommandsTargetOnlyManagedServices() {
        XCTAssertGreaterThan(DockerClient.gracefulStopTimeout, 30)
        XCTAssertEqual(
            DockerClient.stopStackArguments(),
            ["--profile", "tunnel", "stop", "--timeout", "30", "clipboard", "cloudflared"]
        )
        XCTAssertEqual(
            DockerClient.forceStopStackArguments(),
            ["--profile", "tunnel", "kill", "--signal", "SIGKILL", "clipboard", "cloudflared"]
        )
    }

    func testLegacyLifecycleCommandsTargetOnlyLegacyServices() {
        XCTAssertEqual(
            DockerClient.stopLegacyArguments(),
            ["--profile", "tunnel", "stop", "--timeout", "30", "clipboard", "cloudflared"]
        )
        XCTAssertEqual(
            DockerClient.forceStopLegacyArguments(),
            ["--profile", "tunnel", "kill", "--signal", "SIGKILL", "clipboard", "cloudflared"]
        )
        XCTAssertEqual(
            DockerClient.startLegacyArguments(),
            ["--profile", "tunnel", "up", "-d", "--no-build", "clipboard", "cloudflared"]
        )
    }

    func testStableCatalogFilteringAndImageSelection() throws {
        XCTAssertTrue(ClipSyncReleaseCatalog.isStableTag("v1.2.3"))
        XCTAssertFalse(ClipSyncReleaseCatalog.isStableTag("v1.2.3-rc1"))
        XCTAssertFalse(ClipSyncReleaseCatalog.isStableTag("latest"))
        XCTAssertEqual(ClipSyncRelease.tag(fromImage: "ghcr.io/dennis-au/clipsync:v1.2.3"), "v1.2.3")
        XCTAssertNil(ClipSyncRelease.tag(fromImage: "clipsync:latest"))
    }

    func testLegacyProjectDiscoveryUsesDockerLabelsNotAHostSpecificPath() {
        let output = "/Users/other/project/clipsync|/Users/other/project/clipsync/compose.yaml,/Users/other/project/clipsync/compose.cloudflare-tunnel.example.yaml\n/Users/other/project/clipsync|/Users/other/project/clipsync/compose.yaml,/Users/other/project/clipsync/compose.cloudflare-tunnel.example.yaml\n"
        XCTAssertEqual(DockerClient.legacyProjectPaths(from: output), ["/Users/other/project/clipsync"])
        XCTAssertEqual(DockerClient.legacyProjectReferences(from: output), [
            .init(
                directory: "/Users/other/project/clipsync",
                composeFiles: [
                    "/Users/other/project/clipsync/compose.yaml",
                    "/Users/other/project/clipsync/compose.cloudflare-tunnel.example.yaml",
                ]
            ),
        ])
    }

    func testContainerInspectionClassifiesOnlyExactManagedAndUpgradeOwners() throws {
        let stack = ManagedStack(workspace: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClipSync"))
        let current = containerInspectionJSON(
            id: "current-id",
            name: "/clipsync-managed-clipboard-1",
            labels: [
                ManagedStack.ownershipLabel: ManagedStack.ownershipValue,
                ManagedStack.roleLabel: "clipboard",
                "com.docker.compose.project": ManagedStack.projectName,
                "com.docker.compose.service": ManagedStack.clipboardService,
                "com.docker.compose.project.working_dir": stack.workspace.path,
                "com.docker.compose.project.config_files": stack.composeFile.path,
            ]
        )
        let previous = containerInspectionJSON(
            id: "previous-id",
            name: "/clipsync-managed-clipboard-1-old",
            labels: [
                "com.docker.compose.project": ManagedStack.previousProjectName,
                "com.docker.compose.service": "managed-clipboard",
                "com.docker.compose.project.working_dir": stack.workspace.path,
                "com.docker.compose.project.config_files": stack.composeFile.path,
            ]
        )
        let foreign = containerInspectionJSON(
            id: "foreign-id",
            name: "/legacy-clipboard",
            labels: ["com.docker.compose.project": "clipsync"]
        )

        let decoded = try ContainerOwnership.decodeInspections("[\(current),\(previous),\(foreign)]")
        let audit = ContainerOwnership.audit(decoded, stack: stack)

        XCTAssertEqual(audit.currentManaged.map(\.id), ["current-id"])
        XCTAssertEqual(audit.upgradeCompatible.map(\.id), ["previous-id"])
        XCTAssertEqual(audit.foreign.map(\.id), ["foreign-id"])
    }

    func testUpgradeCompatibilityRequiresExactWorkspaceAndComposePath() throws {
        let stack = ManagedStack(workspace: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClipSync"))
        let wrongWorkspace = containerInspectionJSON(
            id: "wrong",
            name: "/wrong",
            labels: [
                "com.docker.compose.project": ManagedStack.previousProjectName,
                "com.docker.compose.service": "managed-clipboard",
                "com.docker.compose.project.working_dir": "/tmp/not-clipsync-control",
                "com.docker.compose.project.config_files": stack.composeFile.path,
            ]
        )
        let decoded = try ContainerOwnership.decodeInspections("[\(wrongWorkspace)]")

        XCTAssertEqual(ContainerOwnership.audit(decoded, stack: stack).foreign.map(\.id), ["wrong"])
    }

    func testOwnershipDecisionsRefuseUnknownAndFailClosedDuringSplitBrain() throws {
        let stack = ManagedStack(workspace: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClipSync"))
        let currentJSON = containerInspectionJSON(
            id: "current",
            name: "/clipsync-managed-clipboard-1",
            labels: [
                ManagedStack.ownershipLabel: ManagedStack.ownershipValue,
                ManagedStack.roleLabel: "clipboard",
                "com.docker.compose.project": ManagedStack.projectName,
                "com.docker.compose.service": ManagedStack.clipboardService,
                "com.docker.compose.project.working_dir": stack.workspace.path,
                "com.docker.compose.project.config_files": stack.composeFile.path,
            ]
        )
        let foreignJSON = containerInspectionJSON(
            id: "foreign",
            name: "/foreign-writer",
            labels: [:]
        )
        let previousJSON = containerInspectionJSON(
            id: "previous",
            name: "/previous-controller",
            labels: [
                "com.docker.compose.project": ManagedStack.previousProjectName,
                "com.docker.compose.service": "managed-clipboard",
                "com.docker.compose.project.working_dir": stack.workspace.path,
                "com.docker.compose.project.config_files": stack.composeFile.path,
            ]
        )
        let current = try ContainerOwnership.decodeInspections("[\(currentJSON)]")[0]
        let foreign = try ContainerOwnership.decodeInspections("[\(foreignJSON)]")[0]
        let previous = try ContainerOwnership.decodeInspections("[\(previousJSON)]")[0]

        let foreignOnly = ContainerOwnership.audit([foreign], stack: stack)
        XCTAssertEqual(ContainerOwnership.startDecision(for: foreignOnly), .refuse("foreign-writer"))
        XCTAssertEqual(ContainerOwnership.runtimeDecision(for: foreignOnly), .refuse("foreign-writer"))

        let splitBrain = ContainerOwnership.audit([current, foreign], stack: stack)
        XCTAssertEqual(ContainerOwnership.startDecision(for: splitBrain), .failClosed("foreign-writer"))
        XCTAssertEqual(ContainerOwnership.runtimeDecision(for: splitBrain), .failClosed("foreign-writer"))
        XCTAssertEqual(ContainerOwnership.postStartDecision(for: splitBrain), .failClosed("foreign-writer"))

        let predecessorOnly = ContainerOwnership.audit([previous], stack: stack)
        XCTAssertEqual(ContainerOwnership.startDecision(for: predecessorOnly), .adoptPrevious)
        XCTAssertEqual(ContainerOwnership.runtimeDecision(for: predecessorOnly), .allow)
    }

    func testOwnershipCommandsAreScopedToExactContainersAndNeverVolumes() {
        let commands = [
            DockerClient.stopContainerArguments(id: "container-id"),
            DockerClient.killContainerArguments(id: "container-id"),
            DockerClient.removeContainerArguments(id: "container-id"),
        ]

        XCTAssertEqual(commands[0], ["container", "stop", "--time", "30", "container-id"])
        XCTAssertEqual(commands[1], ["container", "kill", "--signal", "SIGKILL", "container-id"])
        XCTAssertEqual(commands[2], ["container", "rm", "container-id"])
        for command in commands {
            XCTAssertFalse(command.contains("-v"))
            XCTAssertFalse(command.contains("volume"))
            XCTAssertFalse(command.contains("prune"))
            XCTAssertFalse(command.contains("down"))
        }
    }

    func testOwnershipDiscoveryUsesSharedVolumeAndExplicitLabels() {
        XCTAssertEqual(
            DockerClient.runningVolumeContainerIDsArguments(),
            ["container", "ls", "--filter", "volume=clipsync_clipboard-data", "--format", "{{.ID}}"]
        )
        XCTAssertEqual(
            DockerClient.ownedManagedContainerIDsArguments(),
            ["container", "ls", "--filter", "label=io.clipsync.control.owner=ClipSyncControl", "--format", "{{.ID}}"]
        )
        XCTAssertTrue(DockerClient.previousManagedContainerIDsArguments().contains("--all"))
    }

    func testFailClosedAttemptsClipboardAfterTunnelStopFails() async throws {
        let tunnelJSON = containerInspectionJSON(
            id: "tunnel",
            name: "/tunnel",
            labels: [ManagedStack.roleLabel: "tunnel"]
        )
        let clipboardJSON = containerInspectionJSON(
            id: "clipboard",
            name: "/clipboard",
            labels: [ManagedStack.roleLabel: "clipboard"]
        )
        let tunnel = try ContainerOwnership.decodeInspections("[\(tunnelJSON)]")[0]
        let clipboard = try ContainerOwnership.decodeInspections("[\(clipboardJSON)]")[0]
        var attempts: [String] = []

        let succeeded = await DockerClient.attemptAllOwnedStops([clipboard, tunnel]) { container in
            attempts.append(container.id)
            if container.id == "tunnel" { throw TestMigrationError.stopFailed }
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(attempts, ["tunnel", "clipboard"])
    }

    func testStartAttemptAuditsNonzeroAndThrownComposeResults() async throws {
        var nonzeroAudits: [Bool] = []
        let nonzero = try await DockerClient.performStartAttempt(
            action: { CommandResult(exitCode: 1, standardOutput: "", standardError: "failed") },
            postAttempt: { nonzeroAudits.append($0) }
        )
        XCTAssertEqual(nonzero.exitCode, 1)
        XCTAssertEqual(nonzeroAudits, [false])

        var thrownAudits: [Bool] = []
        do {
            _ = try await DockerClient.performStartAttempt(
                action: { throw TestMigrationError.startFailed },
                postAttempt: { thrownAudits.append($0) }
            )
            XCTFail("Expected original start error")
        } catch TestMigrationError.startFailed {
            XCTAssertEqual(thrownAudits, [false])
        }
    }

    @MainActor
    func testLegacyRollbackDoesNotStartWhenVolumeCannotBeConfirmedUnowned() async {
        var startAttempted = false
        do {
            _ = try await LegacyMigration.restartLegacyWhenSafe(
                confirmVolumeUnowned: { throw TestMigrationError.volumeStillOwned },
                startLegacy: {
                    startAttempted = true
                    return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
                }
            )
            XCTFail("Expected rollback safety failure")
        } catch TestMigrationError.volumeStillOwned {
            XCTAssertFalse(startAttempted)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationOnlyBlocksWhileLegacyServicesAreRunning() {
        XCTAssertTrue(LegacyMigration.hasRunningLegacyServices([
            .init(service: "clipboard", state: "running", health: "healthy"),
            .init(service: "managed-clipboard", state: "running", health: "healthy"),
        ]))
        XCTAssertTrue(LegacyMigration.hasRunningLegacyServices([
            .init(service: "cloudflared", state: "running", health: nil),
        ]))
        XCTAssertFalse(LegacyMigration.hasRunningLegacyServices([
            .init(service: "clipboard", state: "exited", health: nil),
            .init(service: "managed-clipboard", state: "running", health: "healthy"),
        ]))
    }

    func testDownloadedImageInventoryHasStableDigestAndCanBeSelectedOffline() {
        let image = DownloadedClipSyncImage(image: "ghcr.io/dennis-au/clipsync:v0.3.0", digest: "sha256:abc", downloadedAt: Date())
        XCTAssertEqual(image.tag, "v0.3.0")
        XCTAssertTrue(DockerClient.startStackArguments(includeTunnel: false).contains("never"))
    }

    func testRequiredImagesIncludePinnedTunnelOnlyWhenTunnelIsEnabled() {
        XCTAssertEqual(
            DockerClient.requiredImageReferences(clipboardImage: "ghcr.io/dennis-au/clipsync:v0.3.5", includeTunnel: false),
            ["ghcr.io/dennis-au/clipsync:v0.3.5"]
        )
        XCTAssertEqual(
            DockerClient.requiredImageReferences(clipboardImage: "ghcr.io/dennis-au/clipsync:v0.3.5", includeTunnel: true),
            ["ghcr.io/dennis-au/clipsync:v0.3.5", ManagedStack.tunnelImage]
        )
    }

    func testDefaultImageTracksCurrentStableRelease() {
        XCTAssertEqual(ClipSyncRelease.defaultImage, "ghcr.io/dennis-au/clipsync:v0.3.5")
    }

    @MainActor
    func testMigrationPreparesImagesBeforeStoppingLegacy() async throws {
        var steps: [String] = []

        try await LegacyMigration.prepareImagesThenStopLegacy(
            prepareImages: { steps.append("prepare-images") },
            stopLegacy: {
                steps.append("stop-legacy")
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            },
            forceStopLegacy: {
                steps.append("force-stop-legacy")
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            },
            legacyServices: { [] }
        )

        XCTAssertEqual(steps, ["prepare-images", "stop-legacy"])
    }

    @MainActor
    func testMigrationLeavesLegacyRunningWhenImagePreparationFails() async {
        var legacyStopAttempted = false

        do {
            try await LegacyMigration.prepareImagesThenStopLegacy(
                prepareImages: { throw TestMigrationError.imagePreparationFailed },
                stopLegacy: {
                    legacyStopAttempted = true
                    return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
                },
                forceStopLegacy: { CommandResult(exitCode: 0, standardOutput: "", standardError: "") },
                legacyServices: { [] }
            )
            XCTFail("Expected image preparation to stop the transition")
        } catch TestMigrationError.imagePreparationFailed {
            XCTAssertFalse(legacyStopAttempted)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testMigrationForceStopsLegacyOnlyWhenGracefulStopLeavesItRunning() async throws {
        var steps: [String] = []
        var checks = 0

        try await LegacyMigration.prepareImagesThenStopLegacy(
            prepareImages: { steps.append("prepare-images") },
            stopLegacy: {
                steps.append("stop-legacy")
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "")
            },
            forceStopLegacy: {
                steps.append("force-stop-legacy")
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            },
            legacyServices: {
                checks += 1
                return checks == 1 ? [.init(service: "clipboard", state: "running", health: "healthy")] : []
            }
        )

        XCTAssertEqual(steps, ["prepare-images", "stop-legacy", "force-stop-legacy"])
    }

    func testMigrationImagePreparationPullsOnlyRequiredVerifiedServices() {
        XCTAssertEqual(
            DockerClient.migrationImagePreparationArguments(includeTunnel: false),
            ["pull", "--quiet", ManagedStack.clipboardService]
        )
        XCTAssertEqual(
            DockerClient.migrationImagePreparationArguments(includeTunnel: true),
            ["pull", "--quiet", ManagedStack.clipboardService, ManagedStack.tunnelService]
        )
    }

    func testManagedNetworkCreateUsesAutomaticIPAMAndOwnershipLabel() {
        let arguments = DockerClient.managedNetworkCreateArguments()

        XCTAssertEqual(arguments, [
            "network", "create",
            "--driver", "bridge",
            "--label", "\(ManagedStack.managedNetworkOwnershipLabel)=\(ManagedStack.managedNetworkOwnershipValue)",
            ManagedStack.managedNetworkName,
        ])
        XCTAssertFalse(arguments.contains("--subnet"))
        XCTAssertFalse(arguments.contains("rm"))
        XCTAssertFalse(arguments.contains("prune"))
        XCTAssertFalse(arguments.contains("down"))
        XCTAssertEqual(
            DockerClient.managedNetworkInspectArguments(),
            ["network", "inspect", ManagedStack.managedNetworkName, "--format", "{{json .}}"]
        )
    }

    func testManagedNetworkInspectionReturnsOnlyOwnedBridgeCIDR() throws {
        let inspection = #"""
        {"Name":"clipsync-control-managed","Driver":"bridge","Labels":{"io.clipsync.control.managed":"true"},"IPAM":{"Config":[{"Subnet":"192.168.80.0/20"}]}}
        """#

        XCTAssertEqual(try DockerClient.managedNetworkCIDR(from: inspection), "192.168.80.0/20")
    }

    func testManagedNetworkInspectionRejectsForeignOrInvalidNetworks() {
        let examples = [
            #"{"Name":"clipsync-control-managed","Driver":"bridge","Labels":{},"IPAM":{"Config":[{"Subnet":"192.168.80.0/20"}]}}"#,
            #"{"Name":"clipsync-control-managed","Driver":"overlay","Labels":{"io.clipsync.control.managed":"true"},"IPAM":{"Config":[{"Subnet":"192.168.80.0/20"}]}}"#,
            #"{"Name":"clipsync-control-managed","Driver":"bridge","Labels":{"io.clipsync.control.managed":"true"},"IPAM":{"Config":[{"Subnet":"not-a-cidr"}]}}"#,
            #"{"Name":"clipsync-control-managed","Driver":"bridge","Labels":{"io.clipsync.control.managed":"true"},"IPAM":{"Config":[{"Subnet":"10.0.0.0/8"}]}}"#,
            #"{"Name":"another-network","Driver":"bridge","Labels":{"io.clipsync.control.managed":"true"},"IPAM":{"Config":[{"Subnet":"192.168.80.0/20"}]}}"#,
        ]

        for inspection in examples {
            XCTAssertThrowsError(try DockerClient.managedNetworkCIDR(from: inspection)) { error in
                XCTAssertEqual(error as? DockerClientError, .invalidManagedNetwork)
            }
        }
    }

    private func preparedStack() throws -> ManagedStack {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stack = ManagedStack(workspace: directory)
        try stack.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return stack
    }

    private func containerInspectionJSON(
        id: String,
        name: String,
        labels: [String: String],
        running: Bool = true,
        volume: String = ManagedStack.dataVolumeName
    ) -> String {
        let object: [String: Any] = [
            "Id": id,
            "Name": name,
            "State": ["Running": running],
            "Config": ["Labels": labels],
            "Mounts": [["Type": "volume", "Name": volume, "Destination": "/var/lib/clipsync"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum TestMigrationError: Error {
    case imagePreparationFailed, stopFailed, startFailed, volumeStillOwned
}
