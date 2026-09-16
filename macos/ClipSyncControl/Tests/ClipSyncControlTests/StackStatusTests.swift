import XCTest
@testable import ClipSyncControl

final class StackStatusTests: XCTestCase {
    func testImagesMissingStateAllowsPreparation() {
        XCTAssertEqual(StackStatus.imagesMissing.title, "Images need preparation")
        XCTAssertTrue(StackStatus.imagesMissing.canStart)
        XCTAssertFalse(StackStatus.imagesMissing.canStop)
    }

    func testMigrationRequiredExplainsHowToAvoidConcurrentStacks() {
        XCTAssertEqual(
            MigrationError.migrationRequired.errorDescription,
            "A legacy ClipSync stack is still running. Open Settings and use Migrate before starting the managed stack."
        )
    }

    func testManagedStopFailureDoesNotClaimLegacyWasRestarted() {
        XCTAssertEqual(
            MigrationError.managedStopFailed.errorDescription,
            "Managed migration failed, and the managed services could not be stopped safely. Legacy ClipSync was not restarted."
        )
    }

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
