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

    func openPublicClipSync() {
        guard let url = URL(string: settings.publicURL), !settings.publicURL.isEmpty else {
            detail = "Set a public URL in Settings first."
            return
        }
        NSWorkspace.shared.open(url)
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

    private func updateSnapshot(client: DockerClient) async throws {
        let services = try await client.serviceStates()
        let clipboardRunning = services.contains { $0.service == "clipboard" && $0.state == "running" }
        let tunnelRunning = services.contains { $0.service == "cloudflared" && $0.state == "running" }
        let localHealthy = await HealthProbe.localHealthy()

        guard clipboardRunning || localHealthy else {
            snapshot = .off
            detail = "The local stack is stopped."
            return
        }
        guard localHealthy else {
            snapshot = .clipboardUnhealthy
            detail = "The clipboard container is running but its local health check is failing."
            return
        }
        guard tunnelRunning else {
            snapshot = .localHealthyTunnelStopped
            detail = "Local ClipSync is healthy; the Cloudflare tunnel is stopped."
            return
        }
        guard !settings.publicURL.isEmpty else {
            snapshot = .localHealthyPublicUnverified
            detail = "Local ClipSync and the tunnel process are running."
            return
        }
        if await HealthProbe.publicHealthy(baseURL: settings.publicURL) {
            snapshot = .publicReachable
            detail = "Local ClipSync and the configured public endpoint are healthy."
        } else {
            snapshot = .publicUnreachable
            detail = "Local ClipSync is healthy, but the public endpoint did not respond."
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
    }
}
