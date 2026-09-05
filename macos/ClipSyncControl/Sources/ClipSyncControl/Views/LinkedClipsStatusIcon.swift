import AppKit
enum LinkedClipsStatusIcon {
    static let image: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(
            systemSymbolName: "square.on.square",
            accessibilityDescription: "ClipSync"
        )!.withSymbolConfiguration(configuration)!
        image.isTemplate = true
        return image
    }()
}
