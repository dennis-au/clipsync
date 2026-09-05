import AppKit
import SwiftUI
import Vision
import XCTest
@testable import ClipSyncControl

final class SettingsViewTests: XCTestCase {
    @MainActor
    func testSettingsViewRendersDefaultPaneAtSupportedSizes() throws {
        let suiteName = "ClipSyncControlSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("/nonexistent/clipsync-test-project", forKey: "projectPath")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let status = StatusStore(settings: settings)

        for size in [NSSize(width: 980, height: 680), NSSize(width: 780, height: 600)] {
            let rootView = SettingsView()
                .environmentObject(settings)
                .environmentObject(status)
                .preferredColorScheme(.dark)
            let renderedText = try recognizedText(in: rootView, at: size)

            for expectedText in [
                "ClipSync stack",
                "Project folder",
                "Local Docker",
            ] {
                XCTAssertTrue(
                    renderedText.localizedCaseInsensitiveContains(expectedText),
                    "Missing \"\(expectedText)\" at \(Int(size.width))x\(Int(size.height)). Rendered text: \(renderedText)"
                )
            }
        }
    }

    @MainActor
    private func recognizedText<Content: View>(in content: Content, at size: NSSize) throws -> String {
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
