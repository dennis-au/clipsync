import Foundation

enum LegacyMigrationState: Equatable {
    case unknown
    case notNeeded
    case available(projectPath: String)
    case unavailable(String)
}

enum LegacyMigration {
    static func detect(client: DockerClient, legacyPath: String) async throws -> LegacyMigrationState {
        guard try await client.volumeExists(ManagedStack.dataVolumeName) else { return .notNeeded }
        guard let project = try? ProjectValidator.validate(projectPath: legacyPath) else { return .notNeeded }
        guard hasRunningLegacyServices(try await client.legacyServiceStates(project: project)) else { return .notNeeded }
        return .available(projectPath: legacyPath)
    }

    static func hasRunningLegacyServices(_ services: [ComposeService]) -> Bool {
        services.contains { service in
            (service.service == "clipboard" || service.service == "cloudflared") && service.state == "running"
        }
    }

    @MainActor
    static func prepareImagesThenStopLegacy(
        prepareImages: () async throws -> Void,
        stopLegacy: () async throws -> CommandResult
    ) async throws {
        try await prepareImages()
        guard try await stopLegacy().exitCode == 0 else { throw MigrationError.legacyStopFailed }
    }
}
