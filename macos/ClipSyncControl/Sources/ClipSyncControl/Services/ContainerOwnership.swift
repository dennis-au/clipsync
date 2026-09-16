import Foundation

struct DockerContainerInspection: Decodable, Equatable {
    struct ContainerState: Decodable, Equatable {
        let running: Bool

        enum CodingKeys: String, CodingKey { case running = "Running" }
    }

    struct ContainerConfig: Decodable, Equatable {
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey { case labels = "Labels" }
    }

    struct Mount: Decodable, Equatable {
        let type: String?
        let name: String?
        let destination: String?

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case name = "Name"
            case destination = "Destination"
        }
    }

    let id: String
    let name: String
    let state: ContainerState
    let config: ContainerConfig
    let mounts: [Mount]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case state = "State"
        case config = "Config"
        case mounts = "Mounts"
    }

    var displayName: String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    var labels: [String: String] { config.labels ?? [:] }

    func mountsVolume(named volumeName: String) -> Bool {
        mounts.contains { $0.type == "volume" && $0.name == volumeName }
    }
}

enum SharedVolumeOwnerKind: Equatable {
    case currentManaged
    case upgradeCompatible
    case foreign
}

struct SharedVolumeOwner: Equatable {
    let container: DockerContainerInspection
    let kind: SharedVolumeOwnerKind
}

struct ContainerOwnershipAudit: Equatable {
    let owners: [SharedVolumeOwner]

    var currentManaged: [DockerContainerInspection] {
        owners.filter { $0.kind == .currentManaged }.map(\.container)
    }

    var upgradeCompatible: [DockerContainerInspection] {
        owners.filter { $0.kind == .upgradeCompatible }.map(\.container)
    }

    var foreign: [DockerContainerInspection] {
        owners.filter { $0.kind == .foreign }.map(\.container)
    }
}

enum ContainerOwnershipDecision: Equatable {
    case allow
    case adoptPrevious
    case refuse(String)
    case failClosed(String)
}

enum ContainerOwnership {
    static func decodeInspections(_ output: String) throws -> [DockerContainerInspection] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { throw DockerClientError.invalidContainerInspection }
        do {
            return try JSONDecoder().decode([DockerContainerInspection].self, from: data)
        } catch {
            throw DockerClientError.invalidContainerInspection
        }
    }

    static func audit(_ containers: [DockerContainerInspection], stack: ManagedStack) -> ContainerOwnershipAudit {
        let owners = containers
            .filter { $0.state.running && $0.mountsVolume(named: ManagedStack.dataVolumeName) }
            .map { SharedVolumeOwner(container: $0, kind: classify($0, stack: stack)) }
        return ContainerOwnershipAudit(owners: owners)
    }

    static func startDecision(for audit: ContainerOwnershipAudit) -> ContainerOwnershipDecision {
        if !audit.foreign.isEmpty || audit.currentManaged.count > 1 {
            let name = conflictName(from: audit)
            return audit.currentManaged.isEmpty ? .refuse(name) : .failClosed(name)
        }
        if !audit.upgradeCompatible.isEmpty { return .adoptPrevious }
        return .allow
    }

    static func runtimeDecision(for audit: ContainerOwnershipAudit) -> ContainerOwnershipDecision {
        if !audit.foreign.isEmpty {
            let name = conflictName(from: audit)
            return audit.currentManaged.isEmpty ? .refuse(name) : .failClosed(name)
        }
        if audit.currentManaged.count > 1 || (!audit.currentManaged.isEmpty && !audit.upgradeCompatible.isEmpty) {
            return .failClosed(conflictName(from: audit))
        }
        return .allow
    }

    static func postStartDecision(for audit: ContainerOwnershipAudit) -> ContainerOwnershipDecision {
        if audit.foreign.isEmpty, audit.upgradeCompatible.isEmpty, audit.currentManaged.count == 1 {
            return .allow
        }
        return .failClosed(conflictName(from: audit))
    }

    static func isCurrentManaged(_ container: DockerContainerInspection, stack: ManagedStack) -> Bool {
        let labels = container.labels
        return labels[ManagedStack.ownershipLabel] == ManagedStack.ownershipValue
            && labels[ManagedStack.roleLabel] == "clipboard"
            && labels["com.docker.compose.project"] == ManagedStack.projectName
            && labels["com.docker.compose.service"] == ManagedStack.clipboardService
            && labels["com.docker.compose.project.working_dir"] == stack.workspace.path
            && composePaths(from: labels["com.docker.compose.project.config_files"] ?? "").contains(stack.composeFile.path)
    }

    static func isCurrentManagedService(
        _ container: DockerContainerInspection,
        stack: ManagedStack,
        role: String,
        service: String
    ) -> Bool {
        let labels = container.labels
        return labels[ManagedStack.ownershipLabel] == ManagedStack.ownershipValue
            && labels[ManagedStack.roleLabel] == role
            && labels["com.docker.compose.project"] == ManagedStack.projectName
            && labels["com.docker.compose.service"] == service
            && labels["com.docker.compose.project.working_dir"] == stack.workspace.path
            && composePaths(from: labels["com.docker.compose.project.config_files"] ?? "").contains(stack.composeFile.path)
    }

    static func isUpgradeCompatible(_ container: DockerContainerInspection, stack: ManagedStack) -> Bool {
        isUpgradeCompatibleService(container, stack: stack, service: "managed-clipboard")
    }

    static func isUpgradeCompatibleService(
        _ container: DockerContainerInspection,
        stack: ManagedStack,
        service: String
    ) -> Bool {
        let labels = container.labels
        guard labels["com.docker.compose.project"] == ManagedStack.previousProjectName,
              labels["com.docker.compose.service"] == service,
              labels["com.docker.compose.project.working_dir"] == stack.workspace.path else {
            return false
        }
        return composePaths(from: labels["com.docker.compose.project.config_files"] ?? "")
            .contains(stack.composeFile.path)
    }

    static func composePaths(from label: String) -> [String] {
        label.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
    }

    private static func conflictName(from audit: ContainerOwnershipAudit) -> String {
        let container = audit.foreign.first
            ?? audit.upgradeCompatible.first
            ?? audit.currentManaged.dropFirst().first
        return container?.displayName ?? ManagedStack.dataVolumeName
    }

    private static func classify(_ container: DockerContainerInspection, stack: ManagedStack) -> SharedVolumeOwnerKind {
        if isCurrentManaged(container, stack: stack) { return .currentManaged }
        if isUpgradeCompatible(container, stack: stack) { return .upgradeCompatible }
        return .foreign
    }
}
