import AppKit

enum LinkedClipsStatusIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            let clipboard = NSBezierPath()
            clipboard.move(to: NSPoint(x: 6, y: 15.5))
            clipboard.line(to: NSPoint(x: 4.8, y: 15.5))
            clipboard.curve(
                to: NSPoint(x: 3, y: 13.7),
                controlPoint1: NSPoint(x: 3.8, y: 15.5),
                controlPoint2: NSPoint(x: 3, y: 14.7)
            )
            clipboard.line(to: NSPoint(x: 3, y: 3.3))
            clipboard.curve(
                to: NSPoint(x: 4.8, y: 1.5),
                controlPoint1: NSPoint(x: 3, y: 2.3),
                controlPoint2: NSPoint(x: 3.8, y: 1.5)
            )
            clipboard.line(to: NSPoint(x: 13.2, y: 1.5))
            clipboard.curve(
                to: NSPoint(x: 15, y: 3.3),
                controlPoint1: NSPoint(x: 14.2, y: 1.5),
                controlPoint2: NSPoint(x: 15, y: 2.3)
            )
            clipboard.line(to: NSPoint(x: 15, y: 13.7))
            clipboard.curve(
                to: NSPoint(x: 13.2, y: 15.5),
                controlPoint1: NSPoint(x: 15, y: 14.7),
                controlPoint2: NSPoint(x: 14.2, y: 15.5)
            )
            clipboard.line(to: NSPoint(x: 12, y: 15.5))
            clipboard.lineWidth = 1.8
            clipboard.lineCapStyle = .round
            clipboard.lineJoinStyle = .round
            clipboard.stroke()

            let clip = NSBezierPath(roundedRect: NSRect(x: 5.8, y: 14, width: 6.4, height: 3), xRadius: 1.5, yRadius: 1.5)
            clip.lineWidth = 1.8
            clip.stroke()

            let checkmark = NSBezierPath()
            checkmark.move(to: NSPoint(x: 6, y: 8.2))
            checkmark.line(to: NSPoint(x: 8.2, y: 6))
            checkmark.line(to: NSPoint(x: 12.4, y: 10.5))
            checkmark.lineWidth = 2.1
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            checkmark.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClipSync"
        return image
    }()
}
