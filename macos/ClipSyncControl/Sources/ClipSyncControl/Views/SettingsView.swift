import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var status: StatusStore

    var body: some View {
        Form {
            Section("ClipSync stack") {
                TextField("Project folder", text: $settings.projectPath)
                HStack {
                    Button("Choose Folder") { chooseProjectFolder() }
                    Button("Approve Folder") {
                        settings.approveCurrentProject()
                        Task { await status.refresh() }
                    }
                    Button("Remove Approval") { settings.clearApproval() }
                        .disabled(settings.approval == nil)
                }
                Text(settings.setupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Docker") {
                LabeledContent("Docker executable") {
                    Text(settings.dockerPath.isEmpty ? "Automatic discovery" : settings.dockerPath)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Docker CLI") { chooseDockerCLI() }
                    Button("Use Automatic Discovery") { settings.dockerPath = "" }
                        .disabled(settings.dockerPath.isEmpty)
                }
            }

            Section("Public endpoint") {
                TextField("Public URL", text: $settings.publicURL, prompt: Text("Optional"))
                Text("The utility checks this address separately from local health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open this utility at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.updateLaunchAtLogin(enabled: $0) }
                ))
            }

            Section("Current status") {
                Text(status.snapshot.title)
                Text(status.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
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
