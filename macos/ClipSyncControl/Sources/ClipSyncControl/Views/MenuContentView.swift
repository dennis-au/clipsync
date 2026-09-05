import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var status: StatusStore
    let openSettings: () -> Void
    @State private var showStopWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if showStopWarning {
                stopConfirmation
            } else {
                serviceControls
            }

            Divider()
            passwordControls

            Divider()
            connections

            Divider()
            utilityControls

            Divider()
            MenuActionRow(title: "Settings", symbolName: "gear") {
                openSettings()
            }

            Divider()
            MenuActionRow(title: "Quit ClipSync Control", symbolName: "power", isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ClipSync")
                .font(.title3.weight(.semibold))
            HStack(spacing: 7) {
                Image(systemName: status.snapshot.symbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(status.snapshot.title)
                    .font(.subheadline.weight(.medium))
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 15)
    }

    private var serviceControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Service Control")
            MenuActionRow(
                title: "Start ClipSync",
                symbolName: "play.fill",
                isEnabled: !status.isBusy && status.snapshot.canStart
            ) {
                status.start()
            }
            MenuActionRow(
                title: "Stop ClipSync",
                symbolName: "stop.fill",
                isDestructive: true,
                isEnabled: !status.isBusy && status.snapshot.canStop
            ) {
                showStopWarning = true
            }
            MenuActionRow(
                title: "Restart ClipSync",
                symbolName: "arrow.clockwise",
                isEnabled: !status.isBusy && status.snapshot.canStop
            ) {
                status.restart()
            }

            if status.snapshot == .imagesMissing {
                MenuActionRow(
                    title: "Prepare Missing Images",
                    symbolName: "arrow.down.circle",
                    isEnabled: !status.isBusy
                ) {
                    status.prepareImages()
                }
            }
        }
        .padding(.vertical, 11)
    }

    private var stopConfirmation: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Stop ClipSync?")
            Text("Active connections and uploads will be interrupted. Stored room data will be preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)
                .padding(.bottom, 6)
            MenuActionRow(title: "Cancel", symbolName: "xmark") {
                showStopWarning = false
            }
            MenuActionRow(title: "Stop ClipSync", symbolName: "stop.fill", isDestructive: true) {
                showStopWarning = false
                status.stop()
            }
        }
        .padding(.vertical, 11)
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Connections")
            MenuActionRow(title: "Open Local ClipSync", symbolName: "network") {
                status.openLocalClipSync()
            }
        }
        .padding(.vertical, 11)
    }

    private var passwordControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Password")
            MenuActionRow(
                title: "Copy Current Password",
                symbolName: "doc.on.doc",
                isEnabled: !status.isBusy
            ) {
                status.copyCurrentPassword()
            }
            MenuActionRow(
                title: "Generate New Password & Restart",
                symbolName: "key.fill",
                isEnabled: !status.isBusy
            ) {
                status.generatePasswordAndRestart()
            }
        }
        .padding(.vertical, 11)
    }

    private var utilityControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuActionRow(title: "Open Docker Desktop", symbolName: "shippingbox") {
                status.openDockerDesktop()
            }
            MenuActionRow(
                title: "Refresh Status",
                symbolName: "arrow.clockwise",
                isEnabled: !status.isBusy
            ) {
                Task { await status.refresh() }
            }
        }
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
    }

    private var statusColor: Color {
        switch status.snapshot {
        case .localHealthyTunnelStopped, .localHealthyPublicUnverified, .publicReachable:
            .green
        case .starting, .stopping, .imagesMissing:
            .orange
        case .off, .needsApproval:
            .secondary
        case .dockerUnavailable, .clipboardUnhealthy, .publicUnreachable, .error:
            .red
        }
    }
}

private struct MenuActionRow: View {
    let title: String
    let symbolName: String
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.body)
                    .foregroundStyle(textColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .background {
            if isHovered && isEnabled {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.09))
            }
        }
        .accessibilityLabel(title)
    }

    private var textColor: Color {
        guard isEnabled else { return .secondary }
        return isDestructive ? .red : .primary
    }

    private var iconColor: Color {
        guard isEnabled else { return .secondary }
        return isDestructive ? .red : .secondary
    }
}
