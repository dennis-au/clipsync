import AppKit
import XCTest
@testable import ClipSyncControl

final class StatusItemPopoverTests: XCTestCase {
    func testPopoverContentSizeUsesTheVisibleScreenHeight() {
        let contentSize = StatusItemPopoverLayout.contentSize(
            for: NSRect(x: 0, y: 0, width: 1512, height: 560)
        )

        XCTAssertEqual(contentSize.width, StatusItemPopoverLayout.width)
        XCTAssertEqual(contentSize.height, 536)
        XCTAssertLessThanOrEqual(contentSize.height, 560 - StatusItemPopoverLayout.screenMargin)
    }

    func testPopoverContentSizeUsesPreferredHeightWhenThereIsEnoughSpace() {
        let contentSize = StatusItemPopoverLayout.contentSize(
            for: NSRect(x: 0, y: 0, width: 1512, height: 900)
        )

        XCTAssertEqual(contentSize, StatusItemPopoverLayout.defaultContentSize)
    }

    func testPopoverContentSizeAlsoFitsANarrowVisibleScreen() {
        let contentSize = StatusItemPopoverLayout.contentSize(
            for: NSRect(x: 0, y: 0, width: 320, height: 900)
        )

        XCTAssertEqual(contentSize.width, 296)
        XCTAssertEqual(contentSize.height, StatusItemPopoverLayout.preferredHeight)
    }

    func testOutsideClickDismissesButPopoverAndStatusItemClicksDoNot() {
        let popover = NSRect(x: 100, y: 100, width: 350, height: 620)
        let statusItem = NSRect(x: 260, y: 740, width: 24, height: 24)

        XCTAssertFalse(
            StatusItemPopoverDismissal.shouldDismiss(
                mouseLocation: NSPoint(x: 120, y: 120),
                popoverFrame: popover,
                statusItemFrame: statusItem
            )
        )
        XCTAssertFalse(
            StatusItemPopoverDismissal.shouldDismiss(
                mouseLocation: NSPoint(x: 270, y: 750),
                popoverFrame: popover,
                statusItemFrame: statusItem
            )
        )
        XCTAssertTrue(
            StatusItemPopoverDismissal.shouldDismiss(
                mouseLocation: NSPoint(x: 50, y: 50),
                popoverFrame: popover,
                statusItemFrame: statusItem
            )
        )
    }

    func testNoPopoverFrameNeverDismisses() {
        XCTAssertFalse(
            StatusItemPopoverDismissal.shouldDismiss(
                mouseLocation: .zero,
                popoverFrame: nil,
                statusItemFrame: nil
            )
        )
    }
}
