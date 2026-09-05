import AppKit
import Foundation
import XCTest
@testable import ClipSyncControl

final class ProjectValidatorTests: XCTestCase {
    func testStatusIconIsAVisibleTemplateImage() throws {
        let image = LinkedClipsStatusIcon.image

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let visiblePixels = (0..<representation.pixelsHigh).reduce(into: 0) { total, y in
            for x in 0..<representation.pixelsWide where representation.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 {
                total += 1
            }
        }
        XCTAssertGreaterThan(visiblePixels, 40)
    }

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

    func testPasswordStoreReadsAndAtomicallyReplacesPassword() throws {
        let project = try makeProject(environment: "# Keep this comment\nCLIPSYNC_PASSWORD=old-password\nCLIPSYNC_TTL_DAYS=30\n")
        let validated = try ProjectValidator.validate(projectPath: project.path)

        XCTAssertEqual(try ClipSyncPasswordStore.currentPassword(in: validated), "old-password")
        try ClipSyncPasswordStore.replacePassword(in: validated, with: "new_password-123")

        let environment = try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8)
        XCTAssertEqual(environment, "# Keep this comment\nCLIPSYNC_PASSWORD=new_password-123\nCLIPSYNC_TTL_DAYS=30\n")
        XCTAssertEqual(try ClipSyncPasswordStore.currentPassword(in: validated), "new_password-123")
        XCTAssertNoThrow(try ProjectValidator.validate(projectPath: project.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: validated.environmentFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    func testGeneratedPasswordIsURLSafeAndHighEntropyLength() throws {
        let password = try ClipSyncPasswordStore.generatePassword()

        XCTAssertEqual(password.count, 43)
        XCTAssertNotNil(password.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
    }

    func testPasswordRotationComposeArgumentsPreservePersistentData() throws {
        let project = try makeProject()
        let validated = try ProjectValidator.validate(projectPath: project.path)
        let arguments = DockerClient.composeArguments(
            project: validated,
            context: "default",
            action: ["--profile", "tunnel", "up", "-d", "--no-build", "--force-recreate"]
        )

        XCTAssertTrue(arguments.contains("--force-recreate"))
        XCTAssertFalse(arguments.contains("down"))
        XCTAssertFalse(arguments.contains("-v"))
        XCTAssertFalse(arguments.contains("rm"))
    }

    func testRoomDataRequestUsesHashedCookieWithoutExposingPassword() throws {
        let request = RoomDataClient.request(
            baseURL: URL(string: "http://127.0.0.1:8788")!,
            path: "/admin/rooms",
            method: "GET",
            password: "test"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8788/admin/rooms")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "clip_auth=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )
        XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("clip_auth=test") == true)
    }

    func testRoomDataListDecodesRoomMetadata() throws {
        let data = Data(#"{"rooms":[{"name":"alpha","items":2,"bytes":1536},{"name":"beta","items":1,"bytes":42}]}"#.utf8)

        let response = try RoomDataClient.decodeRoomList(data)

        XCTAssertEqual(response.rooms, [
            RoomDataSummary(name: "alpha", itemCount: 2, storedBytes: 1536),
            RoomDataSummary(name: "beta", itemCount: 1, storedBytes: 42),
        ])
    }

    func testClearAllRequestIncludesExplicitDestructiveConfirmation() throws {
        let request = RoomDataClient.clearAllRequest(
            baseURL: URL(string: "http://127.0.0.1:8788")!,
            password: "test"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8788/admin/clear-all")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, RoomDataClient.destructiveRequestTimeout)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Clipsync-Confirm"),
            RoomDataClient.clearAllConfirmation
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "clip_auth=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )
    }

    func testDeleteRoomsRequestContainsOnlySelectedRooms() throws {
        let request = try RoomDataClient.deleteRoomsRequest(
            baseURL: URL(string: "http://127.0.0.1:8788")!,
            password: "test",
            roomNames: ["alpha", "beta"]
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8788/admin/rooms/delete")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, RoomDataClient.destructiveRequestTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(object, ["rooms": ["alpha", "beta"]])
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

    private func makeProject(environment: String = "CLIPSYNC_PASSWORD=test\n") throws -> URL {
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "services:\n  clipboard:\n  cloudflared:\n".write(to: project.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try environment.write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "FROM scratch\n".write(to: project.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(project.path, 0o700), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent("compose.yaml").path, 0o600), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent(".env").path, 0o600), 0)
        XCTAssertEqual(chmod(project.appendingPathComponent("Dockerfile").path, 0o600), 0)
        return project
    }
}
