import XCTest
@testable import ClipSyncControl

final class StackStatusTests: XCTestCase {
    func testHealthyClipboardWithStoppedTunnelOffersTunnelStart() {
        let status = StackStatus.classify(
            services: .init(clipboardRunning: true, tunnelRunning: false, localHealthy: true),
            publicEndpointConfigured: false
        )

        XCTAssertEqual(status, .localHealthyTunnelStopped)
        XCTAssertTrue(status.canStartTunnel)
        XCTAssertFalse(status.canRestartTunnel)
    }

    func testRunningTunnelOffersRestartAndReportsUnreachablePublicEndpoint() {
        let status = StackStatus.classify(
            services: .init(clipboardRunning: true, tunnelRunning: true, localHealthy: true),
            publicEndpointConfigured: true,
            publicEndpointHealthy: false
        )

        XCTAssertEqual(status, .publicUnreachable)
        XCTAssertFalse(status.canStartTunnel)
        XCTAssertTrue(status.canRestartTunnel)
    }

    func testUnhealthyClipboardDoesNotOfferTunnelLifecycleActions() {
        let status = StackStatus.classify(
            services: .init(clipboardRunning: true, tunnelRunning: false, localHealthy: false),
            publicEndpointConfigured: false
        )

        XCTAssertEqual(status, .clipboardUnhealthy)
        XCTAssertFalse(status.canStartTunnel)
        XCTAssertFalse(status.canRestartTunnel)
    }

    func testStoppedStackIsRecognisedWithoutTunnelActions() {
        let status = StackStatus.classify(
            services: .init(clipboardRunning: false, tunnelRunning: false, localHealthy: false),
            publicEndpointConfigured: false
        )

        XCTAssertEqual(status, .off)
        XCTAssertFalse(status.canStartTunnel)
        XCTAssertFalse(status.canRestartTunnel)
    }
}
