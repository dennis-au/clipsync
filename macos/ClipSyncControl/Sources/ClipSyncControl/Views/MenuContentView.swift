import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var status: StatusStore
    @Environment(\.openWindow) private var openWindow
    @State private var showStopWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(status.snapshot.title, systemImage: status.snapshot.symbolName)
                    .font(.headline)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Start ClipSync") { status.start() }
                    .disabled(status.isBusy || !status.snapshot.canStart)
                Button("Stop") { showStopWarning = true }
                    .disabled(status.isBusy || !status.snapshot.canStop)
                Button("Restart") { status.restart() }
                    .disabled(status.isBusy || !status.snapshot.canStop)
            }

            if status.snapshot == .imagesMissing {
                Button("Prepare Missing Images") { status.prepareImages() }
                    .disabled(status.isBusy)
            }

            HStack {
                Button("Open Local") { status.openLocalClipSync() }
                Button("Open Public") { status.openPublicClipSync() }
                    .disabled(settings.publicURL.isEmpty)
            }

            Divider()

            HStack {
                Button("Open Docker Desktop") { status.openDockerDesktop() }
                Button("Refresh") { Task { await status.refresh() } }
                    .disabled(status.isBusy)
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Divider()

            Button("Quit ClipSync Control") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 330)
        .alert("Stop ClipSync?", isPresented: $showStopWarning) {
            Button("Stop", role: .destructive) { status.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active connections and uploads will be interrupted. Stored room data will be preserved.")
        }
    }
}
