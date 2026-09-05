import Foundation

enum StackStatus: Equatable {
    case needsApproval
    case off
    case dockerUnavailable
    case starting
    case stopping
    case clipboardUnhealthy
    case localHealthyTunnelStopped
    case localHealthyPublicUnverified
    case publicUnreachable
    case publicReachable
    case imagesMissing
    case error(String)

    var title: String {
        switch self {
        case .needsApproval: "Setup needs approval"
        case .off: "ClipSync is stopped"
        case .dockerUnavailable: "Docker is unavailable"
        case .starting: "Starting ClipSync"
        case .stopping: "Stopping ClipSync"
        case .clipboardUnhealthy: "Clipboard is unhealthy"
        case .localHealthyTunnelStopped: "Local healthy, tunnel off"
        case .localHealthyPublicUnverified: "Local healthy, tunnel on"
        case .publicUnreachable: "Public check failed"
        case .publicReachable: "Publicly reachable"
        case .imagesMissing: "Images need preparation"
        case .error(let message): message
        }
    }

    var symbolName: String {
        switch self {
        case .off, .needsApproval: "circle"
        case .dockerUnavailable, .clipboardUnhealthy, .publicUnreachable, .error: "exclamationmark.circle"
        case .starting, .stopping: "arrow.triangle.2.circlepath.circle"
        case .localHealthyTunnelStopped, .localHealthyPublicUnverified: "checkmark.circle"
        case .publicReachable: "checkmark.circle.fill"
        case .imagesMissing: "arrow.down.circle"
        }
    }

    var accessibilityLabel: String { title }

    var canStart: Bool {
        switch self {
        case .off, .dockerUnavailable, .clipboardUnhealthy, .localHealthyTunnelStopped, .localHealthyPublicUnverified, .publicUnreachable, .error, .imagesMissing:
            true
        case .needsApproval, .starting, .stopping, .publicReachable:
            false
        }
    }

    var canStop: Bool {
        switch self {
        case .starting, .stopping, .off, .needsApproval, .dockerUnavailable:
            false
        default:
            true
        }
    }
}
