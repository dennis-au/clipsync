import Foundation
import XCTest
@testable import ClipSyncControl

final class ProjectValidatorTests: XCTestCase {
    func testValidatorAcceptsPrivateExpectedProjectShape() throws {
        let project = try makeProject()

        let validated = try ProjectValidator.validate(projectPath: project.path)

        XCTAssertEqual(validated.directory.path, project.path)
        XCTAssertEqual(validated.composeFile.lastPathComponent, "compose.yaml")
    }

    func testValidatorRejectsWorldWritableEnvironmentFile() throws {
        let project = try makeProject()
        let environment = project.appendingPathComponent(".env")
        XCTAssertEqual(chmod(environment.path, 0o666), 0)

        XCTAssertThrowsError(try ProjectValidator.validate(projectPath: project.path)) { error in
            XCTAssertEqual((error as? ProjectValidationError)?.errorDescription, "Permissions are too open for .env.")
        }
    }

    func testStopArgumentsCannotDeletePersistentData() throws {
        let project = try makeProject()
        let validated = try ProjectValidator.validate(projectPath: project.path)
        let arguments = DockerClient.composeArguments(
            project: validated,
            context: "default",
            action: ["--profile", "tunnel", "stop", "--timeout", "30"]
        )

        XCTAssertTrue(arguments.contains("stop"))
        XCTAssertFalse(arguments.contains("down"))
        XCTAssertFalse(arguments.contains("-v"))
        XCTAssertFalse(arguments.contains("prune"))
        XCTAssertFalse(arguments.contains("rm"))
    }

    func testFingerprintChangesWhenComposeChanges() throws {
        let project = try makeProject()
        let first = try ProjectValidator.validate(projectPath: project.path).fingerprint
        let compose = project.appendingPathComponent("compose.yaml")
        try "services:\n  clipboard:\n  cloudflared:\n  extra:\n".write(to: compose, atomically: true, encoding: .utf8)

        let second = try ProjectValidator.validate(projectPath: project.path).fingerprint

        XCTAssertNotEqual(first, second)
    }

    func testProcessRunnerReturnsCommandOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ok"],
            currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 1
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "ok")
    }

    func testProcessRunnerTimesOut() async throws {
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 0.01
            )
            XCTFail("Expected ProcessRunnerError.timedOut")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    private func makeProject() throws -> URL {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "services:\n  clipboard:\n  cloudflared:\n".write(to: project.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "CLIPSYNC_PASSWORD=test\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "FROM scratch\n".write(to: project.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(project.path, 0o700), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent("compose.yaml").path, 0o600), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent(".env").path, 0o600), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent("Dockerfile").path, 0o600), 0)
        return project
    }
}
