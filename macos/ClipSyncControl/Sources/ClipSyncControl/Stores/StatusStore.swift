import AppKit
import Foundation

actor StackOperationCoordinator {
    private var active = false

    func acquire() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    func release() {
        active = false
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot: StackStatus = .needsApproval
    @Published private(set) var isBusy = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var detail = "Review the configured folder in Settings."

    private let settings: SettingsStore
    private let coordinator = StackOperationCoordinator()
    private var observer: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        startObserving()
    }

    deinit {
        observer?.cancel()
    }

    func start() {
        Task { await perform(.start) }
    }

    func stop() {
        Task { await perform(.stop) }
    }

    func restart() {
        Task { await perform(.restart) }
    }

    func startTunnel() {
        Task { await perform(.startTunnel) }
    }

    func restartTunnel() {
        Task { await perform(.restartTunnel) }
    }

    func prepareImages() {
        Task { await perform(.prepareImages) }
    }

    func copyCurrentPassword() {
        guard !isBusy else {
            detail = "Wait for the current ClipSync action to finish."
            return
        }

        do {
            let project = try settings.approvedProject()
            let password = try ClipSyncPasswordStore.currentPassword(in: project)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(password, forType: .string) else {
                throw ClipSyncPasswordStoreError.clipboardWriteFailed
            }
            detail = "Current password copied to the clipboard."
        } catch {
            detail = safeMessage(for: error)
        }
        lastUpdated = Date()
    }

    func generatePasswordAndRestart() {
        Task { await perform(.rotatePassword) }
    }

    func refresh() async {
        guard !isBusy else { return }
        do {
            let project = try settings.approvedProject()
            let client = try DockerClient(project: project, preferredExecutablePath: settings.dockerPath)
            try await client.validateReady()
            try await updateSnapshot(client: client)
        } catch SettingsError.approvalRequired {
            snapshot = .needsApproval
            detail = "Review the project folder in Settings before controlling it."
        } catch DockerClientError.daemonUnavailable, DockerClientError.executableNotFound {
            snapshot = .dockerUnavailable
            detail = "Open Docker Desktop, then refresh this menu."
        } catch {
            snapshot = .error(safeMessage(for: error))
            detail = safeMessage(for: error)
        }
        lastUpdated = Date()
    }

    func openLocalClipSync() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8788")!)
    }

    func openDockerDesktop() {
        let url = URL(fileURLWithPath: "/Applications/Docker.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
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
        guard await coordinator.acquire() else {
            detail = "Another ClipSync action is already running."
            return
        }
        defer { Task { await coordinator.release() } }

        isBusy = true
        defer { isBusy = false }

        do {
            let project = try settings.approvedProject()
            let client = try DockerClient(project: project, preferredExecutablePath: settings.dockerPath)
            try await client.validateReady()

            switch operation {
            case .start:
                snapshot = .starting
                detail = "Starting the local stack and tunnel."
                let result = try await client.start()
                guard result.exitCode == 0 else {
                    snapshot = .imagesMissing
                    detail = "Start failed. Prepare images explicitly, then try again."
                    return
                }
                await waitForLocalHealth(client: client, expectingHealthy: true)
            case .stop:
                snapshot = .stopping
                detail = "Stopping containers. Stored room data is preserved."
                let result = try await client.stop()
                guard result.exitCode == 0 else {
                    throw DockerClientError.invalidConfiguration
                }
                await waitForLocalHealth(client: client, expectingHealthy: false)
            case .restart:
                snapshot = .stopping
                detail = "Stopping active connections before restart."
                let stopped = try await client.stop()
                guard stopped.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
                snapshot = .starting
                detail = "Starting the local stack and tunnel."
                let started = try await client.start()
                guard started.exitCode == 0 else {
                    snapshot = .imagesMissing
                    detail = "Restart needs explicit image preparation."
                    return
                }
                await waitForLocalHealth(client: client, expectingHealthy: true)
            case .startTunnel:
                snapshot = .starting
                detail = "Starting the Cloudflare tunnel. Stored room data is preserved."
                let result = try await client.startTunnel()
                guard result.exitCode == 0 else {
                    snapshot = .imagesMissing
                    detail = "Tunnel start failed. Prepare missing images explicitly, then try again."
                    return
                }
                await waitForTunnel(client: client)
            case .restartTunnel:
                snapshot = .starting
                detail = "Restarting the Cloudflare tunnel. Local ClipSync stays available."
                let result = try await client.restartTunnel()
                guard result.exitCode == 0 else {
                    snapshot = .error("Cloudflare tunnel restart failed")
                    detail = "The tunnel did not restart. Check Docker Desktop, then retry."
                    return
                }
                await waitForTunnel(client: client)
            case .rotatePassword:
                let password = try ClipSyncPasswordStore.generatePassword()
                try ClipSyncPasswordStore.replacePassword(in: project, with: password)
                try settings.recordControllerManagedProjectChange()

                snapshot = .starting
                detail = "Applying the new password and restarting the local stack."
                let result = try await client.applyPasswordChange()
                guard result.exitCode == 0 else {
                    snapshot = .error("Password saved but restart failed")
                    detail = "The new password was saved, but ClipSync did not restart. Check Docker, then restart ClipSync."
                    return
                }
                await waitForLocalHealth(client: client, expectingHealthy: true)
            case .prepareImages:
                snapshot = .starting
                detail = "Preparing only missing local images."
                let result = try await client.prepareMissingImages()
                guard result.exitCode == 0 else { throw DockerClientError.invalidConfiguration }
                snapshot = .off
                detail = "Images are ready. Start ClipSync when you are ready."
            }
        } catch DockerClientError.daemonUnavailable, DockerClientError.executableNotFound {
            snapshot = .dockerUnavailable
            detail = "Docker Desktop is not ready."
        } catch SettingsError.approvalRequired {
            snapshot = .needsApproval
            detail = "Review the project folder in Settings before controlling it."
        } catch {
            snapshot = .error(safeMessage(for: error))
            detail = safeMessage(for: error)
        }
        lastUpdated = Date()
    }

    private func waitForLocalHealth(client: DockerClient, expectingHealthy: Bool) async {
        for _ in 0..<60 {
            let healthy = await HealthProbe.localHealthy()
            if healthy == expectingHealthy {
                do {
                    try await updateSnapshot(client: client)
                } catch {
                    snapshot = .error(safeMessage(for: error))
                    detail = safeMessage(for: error)
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        snapshot = .error("ClipSync startup timed out")
        detail = "The command finished, but health did not settle within two minutes. Refresh or retry manually."
    }

    private func waitForTunnel(client: DockerClient) async {
        for _ in 0..<30 {
            do {
                let services = try await client.serviceStates()
                let tunnelRunning = services.contains { $0.service == "cloudflared" && $0.state == "running" }
                if tunnelRunning {
                    try await updateSnapshot(client: client, services: services)
                    return
                }
            } catch {
                // The next poll may succeed while Compose finishes starting the service.
            }
            try? await Task.sleep(for: .seconds(2))
        }
        snapshot = .localHealthyTunnelStopped
        detail = "The tunnel command finished, but cloudflared did not start within one minute. Check Docker Desktop, then retry."
    }

    private func updateSnapshot(client: DockerClient, services: [ComposeService]? = nil) async throws {
        let currentServices: [ComposeService]
        if let services {
            currentServices = services
        } else {
            currentServices = try await client.serviceStates()
        }
        let serviceState = StackServiceState(
            clipboardRunning: currentServices.contains { $0.service == "clipboard" && $0.state == "running" },
            tunnelRunning: currentServices.contains { $0.service == "cloudflared" && $0.state == "running" },
            localHealthy: await HealthProbe.localHealthy()
        )
        let publicEndpointConfigured = !settings.publicURL.isEmpty
        let publicEndpointHealthy = publicEndpointConfigured
            ? await HealthProbe.publicHealthy(baseURL: settings.publicURL)
            : nil
        snapshot = StackStatus.classify(
            services: serviceState,
            publicEndpointConfigured: publicEndpointConfigured,
            publicEndpointHealthy: publicEndpointHealthy
        )

        switch snapshot {
        case .off:
            detail = "The local stack is stopped."
        case .clipboardUnhealthy:
            detail = "The clipboard container is running but its local health check is failing."
        case .localHealthyTunnelStopped:
            detail = "Local ClipSync is healthy; the Cloudflare tunnel is stopped or unavailable."
        case .localHealthyPublicUnverified:
            detail = "Local ClipSync and the tunnel process are running."
        case .publicUnreachable:
            detail = "Local ClipSync is healthy, but the public endpoint did not respond."
        case .publicReachable:
            detail = "Local ClipSync and the configured public endpoint are healthy."
        default:
            break
        }
    }

    private func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "ClipSync Control could not complete that action."
    }

    private enum Operation {
        case start
        case stop
        case restart
        case rotatePassword
        case prepareImages
        case startTunnel
        case restartTunnel
    }
}
