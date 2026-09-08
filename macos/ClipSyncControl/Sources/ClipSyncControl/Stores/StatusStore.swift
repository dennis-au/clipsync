import AppKit
import Foundation

actor StackOperationCoordinator {
    private var active = false
    func acquire() -> Bool { guard !active else { return false }; active = true; return true }
    func release() { active = false }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot: StackStatus = .off
    @Published private(set) var isBusy = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var detail = "Configure ClipSync in Settings, then start the managed stack."

    private let settings: SettingsStore
    private let coordinator = StackOperationCoordinator()
    private var observer: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        startObserving()
    }

    deinit { observer?.cancel() }

    func start() { Task { await perform(.start) } }
    func stop() { Task { await perform(.stop) } }
    func restart() { Task { await perform(.restart) } }
    func startTunnel() { Task { await perform(.startTunnel) } }
    func restartTunnel() { Task { await perform(.restartTunnel) } }
    func prepareImages() { Task { await perform(.prepareImages) } }
    func updateSelectedImage() { Task { await perform(.updateImage) } }
    func migrateLegacy() { Task { await perform(.migrateLegacy) } }

    func copyCurrentPassword() {
        guard !isBusy else { detail = "Wait for the current ClipSync action to finish."; return }
        do {
            let password = try settings.currentPassword()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(password, forType: .string) else { throw ClipSyncPasswordStoreError.clipboardWriteFailed }
            detail = "Current password copied to the clipboard."
        } catch { detail = safeMessage(for: error) }
        lastUpdated = Date()
    }

    func generatePasswordAndRestart() { Task { await perform(.rotatePassword) } }

    func refresh() async {
        guard !isBusy else { return }
        do {
            let client = try managedClient()
            try await client.validateReady()
            try await updateSnapshot(client: client)
            await settings.detectMigration(using: client)
        } catch DockerClientError.daemonUnavailable, DockerClientError.executableNotFound {
            snapshot = .dockerUnavailable
            detail = "Open Docker Desktop, then refresh this menu."
        } catch {
            snapshot = .error(safeMessage(for: error))
            detail = safeMessage(for: error)
        }
        lastUpdated = Date()
    }

    func openLocalClipSync() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8788")!) }
    func openDockerDesktop() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"), configuration: .init()) { _, _ in }
    }

    private func startObserving() {
        observer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func perform(_ operation: Operation) async {
        guard await coordinator.acquire() else { detail = "Another ClipSync action is already running."; return }
        defer { Task { await coordinator.release() } }
        isBusy = true
        defer { isBusy = false; lastUpdated = Date() }

        do {
            switch operation {
            case .migrateLegacy:
                try await migrateLegacyStack()
            default:
                let requireTunnel = operation == .startTunnel || operation == .restartTunnel
                let client = try managedClient(requireTunnel: requireTunnel)
                try await client.validateReady()
                try await execute(operation, client: client)
            }
        } catch DockerClientError.daemonUnavailable, DockerClientError.executableNotFound {
            snapshot = .dockerUnavailable
            detail = "Docker Desktop is not ready."
        } catch {
            snapshot = .error(safeMessage(for: error))
            detail = safeMessage(for: error)
        }
    }

    private func execute(_ operation: Operation, client: DockerClient) async throws {
        switch operation {
        case .start:
            snapshot = .starting
            let includeTunnel = settings.hasTunnelToken
            detail = includeTunnel ? "Starting the managed local stack and tunnel." : "Starting the managed local stack. Add a tunnel token in Settings to enable Cloudflare."
            let result = try await client.start(includeTunnel: includeTunnel)
            guard result.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForLocalHealth(client: client, expectingHealthy: true)
        case .stop:
            snapshot = .stopping
            detail = "Stopping managed containers. Stored room data is preserved."
            guard try await client.stop().exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForLocalHealth(client: client, expectingHealthy: false)
        case .restart:
            snapshot = .stopping
            detail = "Stopping active connections before restart."
            guard try await client.stop().exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            snapshot = .starting
            let includeTunnel = settings.hasTunnelToken
            detail = "Starting the managed local stack\(includeTunnel ? " and tunnel" : "")."
            guard try await client.start(includeTunnel: includeTunnel).exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForLocalHealth(client: client, expectingHealthy: true)
        case .startTunnel:
            snapshot = .starting
            detail = "Starting the Cloudflare tunnel. Stored room data is preserved."
            guard try await client.startTunnel().exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForTunnel(client: client)
        case .restartTunnel:
            snapshot = .starting
            detail = "Restarting the Cloudflare tunnel. Local ClipSync stays available."
            guard try await client.restartTunnel().exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForTunnel(client: client)
        case .rotatePassword:
            _ = try settings.rotatePassword()
            let newClient = try managedClient()
            snapshot = .starting
            detail = "Applying the new password and recreating the managed service."
            guard try await newClient.applyPasswordChange(includeTunnel: settings.hasTunnelToken).exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            await waitForLocalHealth(client: newClient, expectingHealthy: true)
        case .prepareImages:
            snapshot = .starting
            detail = "Downloading the selected ClipSync and Cloudflare images."
            _ = try await client.prepareMissingImages()
            snapshot = .off
            detail = "Images are ready. Start ClipSync when you are ready."
        case .updateImage:
            snapshot = .starting
            detail = "Downloading \(settings.selectedVersion)."
            _ = try await client.pullSelectedImage()
            let digest = try await client.verifyImageDigest(settings.selectedImage)
            settings.recordDownloadedImage(settings.selectedImage, digest: digest)
            detail = "\(settings.selectedVersion) is downloaded. Restart ClipSync to apply it."
            try await updateSnapshot(client: client)
        case .migrateLegacy:
            break
        }
    }

    private func migrateLegacyStack() async throws {
        guard case .available = settings.migrationState else {
            throw MigrationError.notAvailable
        }
        let legacy = try settings.importLegacyCredentials()
        let managedClient = try self.managedClient()
        try await managedClient.validateReady()
        let includeTunnel = settings.hasTunnelToken

        snapshot = .starting
        detail = "Downloading and verifying the selected image\(includeTunnel ? " and Cloudflare image" : ""). Legacy ClipSync stays running until preparation succeeds."
        do {
            try await LegacyMigration.prepareImagesThenStopLegacy(
                prepareImages: {
                    do {
                        let digest = try await managedClient.prepareMigrationImages(includeTunnel: includeTunnel)
                        self.settings.recordDownloadedImage(self.settings.selectedImage, digest: digest)
                    } catch {
                        throw MigrationError.imagePreparationFailed
                    }
                },
                stopLegacy: { try await managedClient.stopLegacy(project: legacy) }
            )
        } catch {
            if case MigrationError.imagePreparationFailed = error {
                detail = MigrationError.imagePreparationFailed.errorDescription ?? detail
            }
            throw error
        }

        do {
            let client = try self.managedClient()
            snapshot = .starting
            detail = "Starting managed ClipSync with the existing room-data volume."
            guard try await client.start(includeTunnel: settings.hasTunnelToken).exitCode == 0 else { throw DockerClientError.invalidConfiguration }
            guard await waitForLocalHealthSuccess(client: client) else { throw MigrationError.managedHealthFailed }
            _ = try await RoomDataClient(docker: client, password: settings.currentPassword()).listRooms()
            settings.markMigrated()
        } catch {
            let rollbackError = await rollbackLegacy(legacy, managedClient: managedClient)
            if let rollbackError { throw MigrationError.rollbackFailed(rollbackError.localizedDescription) }
            throw MigrationError.managedStartRolledBack
        }
    }

    private func managedClient(requireTunnel: Bool = false) throws -> DockerClient {
        try settings.stack.prepare()
        return try DockerClient(
            stack: settings.stack,
            preferredExecutablePath: settings.dockerPath,
            environmentValues: settings.managedEnvironment(requireTunnel: requireTunnel)
        )
    }

    private func waitForLocalHealth(client: DockerClient, expectingHealthy: Bool) async {
        for _ in 0..<60 {
            if await HealthProbe.localHealthy() == expectingHealthy {
                do { try await updateSnapshot(client: client) } catch { snapshot = .error(safeMessage(for: error)); detail = safeMessage(for: error) }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        snapshot = .error("ClipSync startup timed out")
        detail = "The command finished, but health did not settle within two minutes. Refresh or retry manually."
    }

    private func waitForLocalHealthSuccess(client: DockerClient) async -> Bool {
        for _ in 0..<60 {
            if await HealthProbe.localHealthy() {
                try? await updateSnapshot(client: client)
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func rollbackLegacy(_ legacy: ValidatedProject, managedClient: DockerClient) async -> Error? {
        _ = try? await managedClient.stop()
        do {
            guard try await managedClient.startLegacy(project: legacy).exitCode == 0 else { return MigrationError.legacyRollbackFailed }
            detail = "Managed migration failed. The legacy ClipSync stack was restarted."
            return nil
        } catch {
            return error
        }
    }

    private func waitForTunnel(client: DockerClient) async {
        for _ in 0..<30 {
            do {
                let services = try await client.serviceStates()
                if services.contains(where: { $0.service == ManagedStack.tunnelService && $0.state == "running" }) {
                    try await updateSnapshot(client: client, services: services)
                    return
                }
            } catch { }
            try? await Task.sleep(for: .seconds(2))
        }
        snapshot = .localHealthyTunnelStopped
        detail = "The tunnel command finished, but cloudflared did not start within one minute. Check Docker Desktop, then retry."
    }

    private func updateSnapshot(client: DockerClient, services: [ComposeService]? = nil) async throws {
        let current: [ComposeService]
        if let services {
            current = services
        } else {
            current = try await client.serviceStates()
        }
        let state = StackServiceState(
            clipboardRunning: current.contains { $0.service == ManagedStack.clipboardService && $0.state == "running" },
            tunnelRunning: current.contains { $0.service == ManagedStack.tunnelService && $0.state == "running" },
            localHealthy: await HealthProbe.localHealthy()
        )
        let configured = !settings.publicURL.isEmpty
        let publicHealthy = configured ? await HealthProbe.publicHealthy(baseURL: settings.publicURL) : nil
        snapshot = StackStatus.classify(services: state, publicEndpointConfigured: configured, publicEndpointHealthy: publicHealthy)
        switch snapshot {
        case .off: detail = "The managed local stack is stopped."
        case .clipboardUnhealthy: detail = "The managed clipboard container is running but its local health check is failing."
        case .localHealthyTunnelStopped: detail = "Local ClipSync is healthy; the Cloudflare tunnel is stopped or unavailable."
        case .localHealthyPublicUnverified: detail = "Local ClipSync and the tunnel process are running."
        case .publicUnreachable: detail = "Local ClipSync is healthy, but the configured public endpoint did not respond."
        case .publicReachable: detail = "Local ClipSync and the configured public endpoint are healthy."
        default: break
        }
    }

    private func safeMessage(for error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "ClipSync Control could not complete that action." }

    private enum Operation: Equatable { case start, stop, restart, rotatePassword, prepareImages, startTunnel, restartTunnel, updateImage, migrateLegacy }
}

enum MigrationError: LocalizedError {
    case notAvailable, imagePreparationFailed, legacyStopFailed, managedHealthFailed, managedStartRolledBack, legacyRollbackFailed, rollbackFailed(String)
    var errorDescription: String? {
        switch self {
        case .notAvailable: "No compatible legacy ClipSync stack is available to migrate."
        case .imagePreparationFailed: "The selected ClipSync image could not be prepared. Legacy ClipSync is still running."
        case .legacyStopFailed: "The legacy ClipSync services could not be stopped. No managed containers were started."
        case .managedHealthFailed: "Managed ClipSync did not become healthy after migration."
        case .managedStartRolledBack: "Managed migration failed. The legacy ClipSync stack was restarted."
        case .legacyRollbackFailed: "Managed migration failed and the legacy ClipSync stack could not be restarted."
        case let .rollbackFailed(message): "Managed migration failed and legacy rollback failed: \(message)"
        }
    }
}
