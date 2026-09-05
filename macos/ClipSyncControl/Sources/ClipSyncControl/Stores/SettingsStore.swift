import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let projectPath = "projectPath"
        static let dockerPath = "dockerPath"
        static let publicURL = "publicURL"
        static let approval = "projectApproval"
    }

    @Published var projectPath: String {
        didSet {
            UserDefaults.standard.set(projectPath, forKey: Key.projectPath)
            if oldValue != projectPath {
                approval = nil
                saveApproval()
            }
        }
    }
    @Published var dockerPath: String {
        didSet { UserDefaults.standard.set(dockerPath, forKey: Key.dockerPath) }
    }
    @Published var publicURL: String {
        didSet { UserDefaults.standard.set(publicURL, forKey: Key.publicURL) }
    }
    @Published private(set) var approval: ProjectApproval?
    @Published private(set) var setupMessage = "Review and approve the local ClipSync folder before controlling it."

    init(defaults: UserDefaults = .standard) {
        projectPath = defaults.string(forKey: Key.projectPath) ?? "/Users/dennisau/project/clipsync"
        dockerPath = defaults.string(forKey: Key.dockerPath) ?? ""
        publicURL = defaults.string(forKey: Key.publicURL) ?? ""
        if let data = defaults.data(forKey: Key.approval) {
            approval = try? JSONDecoder().decode(ProjectApproval.self, from: data)
        } else {
            approval = nil
        }
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func approveCurrentProject() {
        do {
            let project = try ProjectValidator.validate(projectPath: projectPath)
            approval = ProjectApproval(path: project.directory.path, fingerprint: project.fingerprint, approvedAt: Date())
            saveApproval()
            setupMessage = "Folder approved. You can now start or stop ClipSync."
        } catch {
            approval = nil
            saveApproval()
            setupMessage = (error as? LocalizedError)?.errorDescription ?? "Could not approve this folder."
        }
    }

    func approvedProject() throws -> ValidatedProject {
        let project = try ProjectValidator.validate(projectPath: projectPath)
        guard let approval, approval.path == project.directory.path, approval.fingerprint == project.fingerprint else {
            throw SettingsError.approvalRequired
        }
        return project
    }

    func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            setupMessage = enabled ? "The utility will open at login." : "Launch at login is disabled."
        } catch {
            setupMessage = "macOS could not change the launch-at-login setting."
        }
    }

    func clearApproval() {
        approval = nil
        saveApproval()
        setupMessage = "Folder approval removed."
    }

    private func saveApproval() {
        if let approval, let data = try? JSONEncoder().encode(approval) {
            UserDefaults.standard.set(data, forKey: Key.approval)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.approval)
        }
    }
}

enum SettingsError: LocalizedError {
    case approvalRequired

    var errorDescription: String? {
        "Review and approve the ClipSync project folder in Settings."
    }
}
