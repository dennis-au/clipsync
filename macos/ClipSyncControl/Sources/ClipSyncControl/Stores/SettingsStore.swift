import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let dockerPath = "dockerPath"
        static let publicURL = "publicURL"
        static let selectedImage = "selectedImage"
        static let legacyProjectPath = "legacyProjectPath"
        static let downloadedImages = "downloadedImages"
    }

    @Published var dockerPath: String { didSet { defaults.set(dockerPath, forKey: Key.dockerPath) } }
    @Published var publicURL: String { didSet { defaults.set(publicURL, forKey: Key.publicURL) } }
    @Published var selectedImage: String { didSet { defaults.set(selectedImage, forKey: Key.selectedImage) } }
    @Published var legacyProjectPath: String { didSet { defaults.set(legacyProjectPath, forKey: Key.legacyProjectPath) } }
    @Published private(set) var setupMessage = "ClipSync Control manages its own private Docker Compose workspace."
    @Published private(set) var availableReleases: [ClipSyncRelease] = []
    @Published private(set) var isLoadingReleases = false
    @Published private(set) var migrationState: LegacyMigrationState = .unknown
    @Published private(set) var downloadedImages: [DownloadedClipSyncImage] = []

    let stack: ManagedStack
    let secrets: KeychainSecretStore
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        stack: ManagedStack = ManagedStack(),
        secrets: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.defaults = defaults
        self.stack = stack
        self.secrets = secrets
        dockerPath = defaults.string(forKey: Key.dockerPath) ?? ""
        publicURL = defaults.string(forKey: Key.publicURL) ?? ""
        selectedImage = defaults.string(forKey: Key.selectedImage) ?? ClipSyncRelease.defaultImage
        legacyProjectPath = defaults.string(forKey: Key.legacyProjectPath) ?? ""
        downloadedImages = (try? JSONDecoder().decode([DownloadedClipSyncImage].self, from: defaults.data(forKey: Key.downloadedImages) ?? Data())) ?? []
        do {
            try stack.prepare()
        } catch {
            setupMessage = safeMessage(for: error)
        }
    }

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var managedWorkspacePath: String { stack.workspace.path }
    var hasPassword: Bool { (try? secrets.value(for: .password)) != nil }
    var hasTunnelToken: Bool { (try? secrets.value(for: .tunnelToken)) != nil }
    var selectedVersion: String { ClipSyncRelease.tag(fromImage: selectedImage) ?? selectedImage }

    func managedEnvironment(requireTunnel: Bool = false) throws -> ManagedEnvironmentValues {
        let password: String
        if let stored = try secrets.value(for: .password) {
            password = stored
        } else {
            password = try ClipSyncPasswordStore.generatePassword()
            try secrets.set(password, for: .password)
        }
        let token = try secrets.value(for: .tunnelToken)
        if requireTunnel && token == nil { throw TunnelConfigurationError.tokenRequired }
        return ManagedEnvironmentValues(image: selectedImage, password: password, tunnelToken: token)
    }

    func currentPassword() throws -> String {
        guard let password = try secrets.value(for: .password) else { throw ManagedStackError.secretMissing }
        return password
    }

    func rotatePassword() throws -> String {
        let password = try ClipSyncPasswordStore.generatePassword()
        try secrets.set(password, for: .password)
        return password
    }

    func setTunnelToken(_ token: String) throws {
        try secrets.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .tunnelToken)
        setupMessage = "Cloudflare tunnel token is stored in your macOS Keychain."
    }

    func removeTunnelConfiguration() {
        do {
            try secrets.remove(.tunnelToken)
            publicURL = ""
            setupMessage = "Cloudflare tunnel configuration was removed from this Mac."
        } catch {
            setupMessage = safeMessage(for: error)
        }
    }

    func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            setupMessage = enabled ? "The utility will open at login." : "Launch at login is disabled."
        } catch {
            setupMessage = "macOS could not change the launch-at-login setting."
        }
    }

    func loadStableReleases() async {
        guard !isLoadingReleases else { return }
        isLoadingReleases = true
        defer { isLoadingReleases = false }
        do {
            availableReleases = try await ClipSyncReleaseCatalog.fetchStableReleases()
            if !availableReleases.contains(where: { $0.image == selectedImage }), let newest = availableReleases.first {
                selectedImage = newest.image
            }
            setupMessage = "Found \(availableReleases.count) stable ClipSync release\(availableReleases.count == 1 ? "" : "s")."
        } catch {
            setupMessage = "Could not check GitHub releases. The selected local image remains available."
        }
    }

    func detectMigration(using client: DockerClient) async {
        do {
            let discovered = try await client.discoveredLegacyProject()
            if let discovered { legacyProjectPath = discovered.directory.path }
            migrationState = try await LegacyMigration.detect(client: client, legacyPath: legacyProjectPath)
            downloadedImages = try await client.downloadedClipSyncImages()
            saveDownloadedImages()
        } catch {
            migrationState = .unavailable(safeMessage(for: error))
        }
    }

    func importLegacyCredentials() throws -> ValidatedProject {
        let project = try ProjectValidator.validate(projectPath: legacyProjectPath)
        let password = try ClipSyncPasswordStore.currentPassword(in: project)
        try secrets.set(password, for: .password)
        if let token = try ClipSyncPasswordStore.currentTunnelToken(in: project) {
            try secrets.set(token, for: .tunnelToken)
        }
        return project
    }

    func markMigrated() { setupMessage = "Legacy services were stopped. Managed ClipSync now uses the existing room-data volume." }
    func markMigrationFailure(_ error: Error) { setupMessage = safeMessage(for: error) }

    func recordDownloadedImage(_ image: String, digest: String) {
        downloadedImages.removeAll { $0.image == image }
        downloadedImages.append(DownloadedClipSyncImage(image: image, digest: digest, downloadedAt: Date()))
        downloadedImages.sort { ClipSyncReleaseCatalog.isHigher($0.tag, than: $1.tag) }
        saveDownloadedImages()
    }

    func useDownloadedImage(_ image: DownloadedClipSyncImage) {
        selectedImage = image.image
        setupMessage = "Selected downloaded \(image.tag) (\(image.digest.prefix(19))...). Restart ClipSync to apply it without a network pull."
    }

    private func saveDownloadedImages() {
        if let data = try? JSONEncoder().encode(downloadedImages) {
            defaults.set(data, forKey: Key.downloadedImages)
        }
    }

    private func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "ClipSync Control could not complete that action."
    }
}

enum TunnelConfigurationError: LocalizedError {
    case tokenRequired

    var errorDescription: String? { "Add a Cloudflare tunnel token in Settings before starting the tunnel." }
}
