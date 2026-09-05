import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var status: StatusStore
    @State private var selection: SettingsSection? = .stack

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("ClipSync")
        } detail: {
            Group {
                switch selection ?? .stack {
                case .stack:
                    StackSettingsPane(
                        settings: settings,
                        status: status,
                        chooseProjectFolder: chooseProjectFolder,
                        chooseDockerCLI: chooseDockerCLI
                    )
                case .connection:
                    ConnectionSettingsPane(settings: settings)
                case .startup:
                    StartupSettingsPane(settings: settings)
                case .about:
                    AboutSettingsPane(status: status)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
        .frame(minWidth: 780, minHeight: 600)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.projectPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.projectPath = url.path
        }
    }

    private func chooseDockerCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.dockerPath = url.path
        }
    }
}

private enum SettingsSection: CaseIterable, Hashable, Identifiable {
    case stack
    case connection
    case startup
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .stack: "Stack"
        case .connection: "Connection"
        case .startup: "Startup"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .stack: "shippingbox"
        case .connection: "network"
        case .startup: "power"
        case .about: "info.circle"
        }
    }
}

private struct StackSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var status: StatusStore
    let chooseProjectFolder: () -> Void
    let chooseDockerCLI: () -> Void

    var body: some View {
        SettingsPane(title: "ClipSync stack", subtitle: "Configure the local project this utility is allowed to control.") {
            SettingsGroup(title: "Project folder") {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                        .frame(width: 24)
                    Text(settings.projectPath)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 16)
                    Button("Choose…", action: chooseProjectFolder)
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: settings.approval == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(settings.approval == nil ? .orange : .green)
                        .font(.body)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.approval == nil ? "Folder needs approval" : "Folder approved")
                            .font(.body.weight(.medium))
                        Text(settings.setupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if settings.approval == nil {
                        Button("Approve Folder") {
                            settings.approveCurrentProject()
                            Task { await status.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Remove Approval", role: .destructive) {
                            settings.clearApproval()
                            Task { await status.refresh() }
                        }
                    }
                }
            }

            SettingsGroup(title: "Local Docker") {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.cyan)
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.dockerPath.isEmpty ? "Docker Desktop" : "Custom Docker CLI")
                            .font(.body.weight(.medium))
                        Text(settings.dockerPath.isEmpty ? "Automatic discovery" : settings.dockerPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(settings.dockerPath.isEmpty ? "Automatic" : "Selected")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }

                Divider()

                HStack {
                    Text("Docker executable")
                    Spacer()
                    Button("Choose CLI…", action: chooseDockerCLI)
                    if !settings.dockerPath.isEmpty {
                        Button("Use Automatic") { settings.dockerPath = "" }
                    }
                }
            }
        }
    }
}

private struct ConnectionSettingsPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsPane(title: "Connection", subtitle: "An optional public address lets ClipSync Control verify the tunnel separately from local health.") {
            SettingsGroup(title: "Public endpoint") {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Public URL")
                        .frame(width: 120, alignment: .leading)
                    TextField("Optional HTTPS URL", text: $settings.publicURL)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Leave this empty to use local health and the running tunnel process as the status signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 136)
            }
        }
    }
}

private struct StartupSettingsPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsPane(title: "Startup", subtitle: "This preference starts the controller utility only. ClipSync itself follows Docker's existing restart policy.") {
            SettingsGroup(title: "Login item") {
                Toggle("Open ClipSync Control at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.updateLaunchAtLogin(enabled: $0) }
                ))
                Text("Starting this utility does not start the clipboard service automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AboutSettingsPane: View {
    @ObservedObject var status: StatusStore

    var body: some View {
        SettingsPane(title: "About", subtitle: "Local controls for the ClipSync Docker Compose stack.") {
            SettingsGroup(title: "Current status") {
                Label(status.snapshot.title, systemImage: status.snapshot.symbolName)
                    .font(.body.weight(.medium))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsGroup(title: "ClipSync Control") {
                LabeledContent("Version", value: "1.0")
                Text("The controller preserves ClipSync data when stopping services and never removes Docker volumes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
