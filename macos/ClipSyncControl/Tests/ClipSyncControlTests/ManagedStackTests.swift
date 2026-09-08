import Foundation
import XCTest
@testable import ClipSyncControl

final class ManagedStackTests: XCTestCase {
    func testManagedComposeUsesExternalDataVolumeAndPinnedTunnel() throws {
        let stack = try preparedStack()
        let compose = try String(contentsOf: stack.composeFile, encoding: .utf8)

        XCTAssertTrue(compose.contains("managed-clipboard:"))
        XCTAssertTrue(compose.contains("managed-cloudflared:"))
        XCTAssertTrue(compose.contains("external: true"))
        XCTAssertTrue(compose.contains("name: clipsync_clipboard-data"))
        XCTAssertTrue(compose.contains("127.0.0.1:8788:8787"))
        XCTAssertTrue(compose.contains("aliases: [clipboard]"))
        XCTAssertTrue(compose.contains("cloudflare/cloudflared:2026.8.2@sha256:"))
        XCTAssertFalse(compose.contains("container_name:"))
        XCTAssertFalse(compose.contains("build:"))
    }

    func testTemporaryEnvironmentIsPrivateAndRemoved() throws {
        let stack = try preparedStack()
        let secret = "very-secret-value"
        let file = try ManagedEnvironmentFile.create(
            in: stack,
            values: ManagedEnvironmentValues(image: "ghcr.io/dennis-au/clipsync:v0.3.0", password: secret, tunnelToken: "token-value")
        )
        defer { ManagedEnvironmentFile.destroy(file) }

        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value, 0o600)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("CLIPSYNC_PASSWORD=\(secret)"))
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
            DockerClient.applyPasswordChangeArguments(includeTunnel: true),
            DockerClient.composeArguments(stack: stack, environmentFile: environment, context: "desktop-linux", action: ["config", "--quiet"]),
        ]
        for arguments in actions {
            XCTAssertFalse(arguments.contains("down"))
            XCTAssertFalse(arguments.contains("-v"))
            XCTAssertFalse(arguments.contains("rm"))
            XCTAssertFalse(arguments.contains("prune"))
            XCTAssertTrue(arguments.joined(separator: " ").contains("--project-name clipsync") || arguments == DockerClient.stopStackArguments() || arguments == DockerClient.startStackArguments(includeTunnel: false) || arguments == DockerClient.applyPasswordChangeArguments(includeTunnel: true))
        }
    }

    func testStableCatalogFilteringAndImageSelection() throws {
        XCTAssertTrue(ClipSyncReleaseCatalog.isStableTag("v1.2.3"))
        XCTAssertFalse(ClipSyncReleaseCatalog.isStableTag("v1.2.3-rc1"))
        XCTAssertFalse(ClipSyncReleaseCatalog.isStableTag("latest"))
        XCTAssertEqual(ClipSyncRelease.tag(fromImage: "ghcr.io/dennis-au/clipsync:v1.2.3"), "v1.2.3")
        XCTAssertNil(ClipSyncRelease.tag(fromImage: "clipsync:latest"))
    }

    func testLegacyProjectDiscoveryUsesDockerLabelsNotAHostSpecificPath() {
        let output = "/Users/other/project/clipsync|/Users/other/project/clipsync/compose.yaml\n/Users/other/project/clipsync|/Users/other/project/clipsync/compose.yaml\n"
        XCTAssertEqual(DockerClient.legacyProjectPaths(from: output), ["/Users/other/project/clipsync"])
    }

    func testDownloadedImageInventoryHasStableDigestAndCanBeSelectedOffline() {
        let image = DownloadedClipSyncImage(image: "ghcr.io/dennis-au/clipsync:v0.3.0", digest: "sha256:abc", downloadedAt: Date())
        XCTAssertEqual(image.tag, "v0.3.0")
        XCTAssertTrue(DockerClient.startStackArguments(includeTunnel: false).contains("never"))
    }

    @MainActor
    func testMigrationPreparesImagesBeforeStoppingLegacy() async throws {
        var steps: [String] = []

        try await LegacyMigration.prepareImagesThenStopLegacy(
            prepareImages: { steps.append("prepare-images") },
            stopLegacy: {
                steps.append("stop-legacy")
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }
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
                }
            )
            XCTFail("Expected image preparation to stop the transition")
        } catch TestMigrationError.imagePreparationFailed {
            XCTAssertFalse(legacyStopAttempted)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    private func preparedStack() throws -> ManagedStack {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stack = ManagedStack(workspace: directory)
        try stack.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return stack
    }
}

private enum TestMigrationError: Error {
    case imagePreparationFailed
}
