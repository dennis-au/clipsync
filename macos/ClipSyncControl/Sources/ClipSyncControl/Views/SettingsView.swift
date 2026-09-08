import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var status: StatusStore
    @State private var selection = SettingsSection.stack

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ClipSync")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case .stack:
                        StackSettingsPane(
                            settings: settings,
                            status: status,
                            chooseLegacyProject: chooseLegacyProject,
                            chooseDockerCLI: chooseDockerCLI
                        )
                    case .connection:
                        ConnectionSettingsPane(settings: settings)
                    case .roomData:
                        RoomDataSettingsPane(settings: settings)
                    case .startup:
                        StartupSettingsPane(settings: settings)
                    case .about:
                        AboutSettingsPane(status: status)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 540, alignment: .topLeading)
                .padding(30)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 600)
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

    private func chooseLegacyProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.legacyProjectPath = url.path
        }
    }
}

private enum SettingsSection: CaseIterable, Hashable, Identifiable {
    case stack
    case connection
    case roomData
    case startup
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .stack: "Stack"
        case .connection: "Connection"
        case .roomData: "Room Data"
        case .startup: "Startup"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .stack: "shippingbox"
        case .connection: "network"
        case .roomData: "externaldrive"
        case .startup: "power"
        case .about: "info.circle"
        }
    }
}

private struct RoomDataSettingsPane: View {
    @StateObject private var roomData: RoomDataStore
    @State private var pendingDeletion: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var deleteAllRequested = false

    init(settings: SettingsStore) {
        _roomData = StateObject(wrappedValue: RoomDataStore(settings: settings))
    }

    var body: some View {
        SettingsPane(
            title: "Room data",
            subtitle: "Review non-empty rooms stored by the local ClipSync service and permanently delete selected data."
        ) {
            SettingsGroup(title: "Stored rooms") {
                HStack(spacing: 12) {
                    Button {
                        Task { await roomData.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(roomData.isLoading || roomData.isDeleting)

                    Spacer()

                    if !roomData.rooms.isEmpty {
                        Button(roomData.allSelected ? "Deselect All" : "Select All") {
                            roomData.toggleAll()
                        }
                        .disabled(roomData.isDeleting)

                        Button("Delete Selected…", role: .destructive) {
                            requestDeletion(roomData.selectedRooms)
                        }
                        .disabled(roomData.selectedRooms.isEmpty || roomData.isDeleting)
                    }
                }

                Divider()

                roomList

                if let errorMessage = roomData.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !roomData.message.isEmpty {
                    Text(roomData.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete all room data")
                            .font(.body.weight(.medium))
                        Text("Removes every stored item and incomplete upload from the local service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Delete All Data…", role: .destructive) {
                        pendingDeletion = []
                        deleteAllRequested = true
                        showDeleteConfirmation = true
                    }
                    .disabled(roomData.isLoading || roomData.isDeleting)
                }
            }
        }
        .task {
            await roomData.refresh()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if deleteAllRequested {
                Button("Delete All Data", role: .destructive) {
                    deleteAllRequested = false
                    Task { await roomData.clearAllData() }
                }
            } else {
                Button(deletionButtonTitle, role: .destructive) {
                    let rooms = pendingDeletion
                    pendingDeletion = []
                    Task { await roomData.deleteRooms(rooms) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = []
                deleteAllRequested = false
            }
        } message: {
            Text(deletionMessage)
        }
    }

    @ViewBuilder
    private var roomList: some View {
        if roomData.isLoading && roomData.rooms.isEmpty {
            HStack {
                Spacer()
                ProgressView("Loading rooms…")
                Spacer()
            }
            .frame(height: 160)
        } else if roomData.rooms.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No stored room data")
                    .font(.headline)
                Text("Only rooms containing one or more items appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roomData.rooms) { room in
                        RoomDataRow(
                            room: room,
                            isSelected: roomData.selectedRooms.contains(room.name),
                            isEnabled: !roomData.isDeleting,
                            toggleSelection: { roomData.toggleSelection(for: room.name) },
                            delete: { requestDeletion([room.name]) }
                        )
                        if room.id != roomData.rooms.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 260)
        }
    }

    private var deletionTitle: String {
        if deleteAllRequested {
            return "Delete all ClipSync data?"
        }
        return pendingDeletion.count == 1 ? "Delete this room's data?" : "Delete \(pendingDeletion.count) rooms' data?"
    }

    private var deletionButtonTitle: String {
        pendingDeletion.count == 1 ? "Delete Room" : "Delete \(pendingDeletion.count) Rooms"
    }

    private var deletionMessage: String {
        if deleteAllRequested {
            return "Every room, text item, image, file, and incomplete upload will be permanently deleted. This cannot be undone."
        }
        return "All text, images, and files in the selected room\(pendingDeletion.count == 1 ? "" : "s") will be permanently deleted. This cannot be undone."
    }

    private func requestDeletion(_ rooms: Set<String>) {
        guard !rooms.isEmpty else { return }
        pendingDeletion = rooms
        deleteAllRequested = false
        showDeleteConfirmation = true
    }
}

private struct RoomDataRow: View {
    let room: RoomDataSummary
    let isSelected: Bool
    let isEnabled: Bool
    let toggleSelection: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(isSelected ? "Deselect \(room.name)" : "Select \(room.name)")

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(room.itemCount) item\(room.itemCount == 1 ? "" : "s") · \(formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("Delete this room's data")
            .accessibilityLabel("Delete \(room.name)")
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: room.storedBytes, countStyle: .file)
    }
}

private struct StackSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var status: StatusStore
    let chooseLegacyProject: () -> Void
    let chooseDockerCLI: () -> Void
    @State private var showMigrationConfirmation = false

    var body: some View {
        SettingsPane(title: "ClipSync stack", subtitle: "This app manages a private Docker Compose workspace and keeps stored room data in the existing Docker volume.") {
            SettingsGroup(title: "Managed workspace") {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark")
                        .foregroundStyle(.blue)
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("App-managed stack")
                            .font(.body.weight(.medium))
                        Text(settings.managedWorkspacePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 16)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Existing room-data volume")
                        .font(.body.weight(.medium))
                        Text("Migration only stops legacy services and reuses \(ManagedStack.dataVolumeName). It never deletes the volume or the legacy project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if case .available = settings.migrationState {
                        Button("Migrate…") { showMigrationConfirmation = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(status.isBusy)
                    Spacer(minLength: 16)
                    } else {
                        Text(migrationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(settings.legacyProjectPath.isEmpty ? "Legacy stack is discovered automatically from Docker labels." : settings.legacyProjectPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Legacy Folder…", action: chooseLegacyProject)
                }
            }

            SettingsGroup(title: "ClipSync version") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Selected image")
                        Text(settings.selectedImage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(settings.isLoadingReleases ? "Checking…" : "Check for Updates") {
                        Task { await settings.loadStableReleases() }
                    }
                    .disabled(settings.isLoadingReleases || status.isBusy)
                }
                if !settings.downloadedImages.isEmpty {
                    Picker("Downloaded version", selection: Binding(
                        get: { settings.selectedImage },
                        set: { settings.selectedImage = $0 }
                    )) {
                        ForEach(settings.downloadedImages) { image in
                            Text("\(image.tag) · \(image.digest.prefix(19))").tag(image.image)
                        }
                    }
                    Button("Use Downloaded Version") {
                        if let image = settings.downloadedImages.first(where: { $0.image == settings.selectedImage }) {
                            settings.useDownloadedImage(image)
                        }
                    }
                    .disabled(!settings.downloadedImages.contains(where: { $0.image == settings.selectedImage }))
                }
                if !settings.availableReleases.isEmpty {
                    Picker("Stable release", selection: $settings.selectedImage) {
                        ForEach(settings.availableReleases) { release in
                            Text(release.tagName).tag(release.image)
                        }
                    }
                }
                HStack {
                    Text("Choose a previously downloaded release to roll back, or choose a newer stable release and download it explicitly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download Selected") { status.updateSelectedImage() }
                        .disabled(status.isBusy)
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
        .confirmationDialog("Migrate existing ClipSync data?", isPresented: $showMigrationConfirmation, titleVisibility: .visible) {
            Button("Stop Legacy and Migrate", role: .destructive) { status.migrateLegacy() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("ClipSync Control will import the legacy password into Keychain, stop legacy containers, and start the managed stack using the same room-data volume. No volume, image, or legacy project files will be deleted.")
        }
    }

    private var migrationDescription: String {
        switch settings.migrationState {
        case .unknown: "Refresh status to check for a compatible legacy stack."
        case .notNeeded: "No compatible legacy stack is waiting to migrate."
        case .available: "A compatible legacy stack is ready to migrate."
        case let .unavailable(message): message
        }
    }
}

private struct ConnectionSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var tunnelToken = ""

    var body: some View {
        SettingsPane(title: "Cloudflare Tunnel", subtitle: "Configure the remote tunnel token in macOS Keychain. ClipSync connects through Docker Desktop; this app never stores the token in project files.") {
            SettingsGroup(title: "Tunnel token") {
                HStack {
                    Label(settings.hasTunnelToken ? "Token saved in Keychain" : "No tunnel token configured", systemImage: settings.hasTunnelToken ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(settings.hasTunnelToken ? .green : .orange)
                    Spacer()
                    if settings.hasTunnelToken {
                        Button("Remove", role: .destructive) { settings.removeTunnelConfiguration() }
                    }
                }
                SecureField("Paste remotely managed tunnel token", text: $tunnelToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save Token") {
                        do { try settings.setTunnelToken(tunnelToken); tunnelToken = "" } catch { }
                    }
                    .disabled(tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Open Cloudflare dashboard", destination: URL(string: "https://one.dash.cloudflare.com/")!)
                }
                Text("Create a remotely managed tunnel in Cloudflare, map its public hostname to http://clipboard:8787, then paste its token here. Cloudflare Access is recommended before exposing ClipSync publicly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(title: "Public endpoint") {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Public URL")
                        .frame(width: 120, alignment: .leading)
                    TextField("Optional HTTPS URL", text: $settings.publicURL)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Use the public HTTPS URL only for health checks. Leave it empty to use the local service and tunnel process as the status signal.")
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
