import Foundation

enum LegacyMigrationState: Equatable {
    case unknown
    case notNeeded
    case available(projectPath: String)
    case unavailable(String)
}

enum LegacyMigration {
    static func detect(client: DockerClient, project: ValidatedProject?) async throws -> LegacyMigrationState {
        guard let project else { return .notNeeded }
        guard try await client.volumeExists(ManagedStack.dataVolumeName) else { return .notNeeded }
        return detect(
            volumeExists: true,
            project: project,
            services: try await client.legacyServiceStates(project: project)
        )
    }

    static func detect(
        volumeExists: Bool,
        project: ValidatedProject?,
        services: [ComposeService]
    ) -> LegacyMigrationState {
        guard volumeExists, let project, hasRunningLegacyServices(services) else { return .notNeeded }
        return .available(projectPath: project.directory.path)
    }

    static func hasRunningLegacyServices(_ services: [ComposeService]) -> Bool {
        services.contains { service in
            (service.service == "clipboard" || service.service == "cloudflared") && service.state == "running"
        }
    }

    @MainActor
    static func restartLegacyWhenSafe(
        confirmVolumeUnowned: () async throws -> Void,
        startLegacy: () async throws -> CommandResult
    ) async throws -> CommandResult {
        try await confirmVolumeUnowned()
        return try await startLegacy()
    }

    @MainActor
    static func prepareImagesThenStopLegacy(
        prepareImages: () async throws -> Void,
        stopLegacy: () async throws -> CommandResult,
        forceStopLegacy: () async throws -> CommandResult,
        legacyServices: () async throws -> [ComposeService]
    ) async throws {
        try await prepareImages()
        do {
            _ = try await stopLegacy()
        } catch ProcessRunnerError.timedOut {
            // The process deadline elapsed before Docker confirmed the graceful stop.
        }
        if !hasRunningLegacyServices(try await legacyServices()) { return }

        guard try await forceStopLegacy().exitCode == 0,
              !hasRunningLegacyServices(try await legacyServices()) else {
            throw MigrationError.legacyStopFailed
        }
    }
}
