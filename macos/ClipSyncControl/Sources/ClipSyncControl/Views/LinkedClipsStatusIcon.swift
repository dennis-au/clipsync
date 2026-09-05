import AppKit
import SwiftUI

enum LinkedClipsStatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        NSColor.black.setStroke()
        let strokeWidth: CGFloat = 1.8
        let rear = NSBezierPath(
            roundedRect: NSRect(x: 2.6, y: 2.6, width: 9.6, height: 10.1),
            xRadius: 1.8,
            yRadius: 1.8
        )
        rear.lineWidth = strokeWidth
        rear.stroke()

        let front = NSBezierPath(
            roundedRect: NSRect(x: 6.1, y: 5.6, width: 9.6, height: 10.1),
            xRadius: 1.8,
            yRadius: 1.8
        )
        front.lineWidth = strokeWidth
        front.stroke()

        let connector = NSBezierPath()
        connector.move(to: NSPoint(x: 7.4, y: 8.9))
        connector.line(to: NSPoint(x: 11.1, y: 8.9))
        connector.lineWidth = strokeWidth
        connector.lineCapStyle = .round
        connector.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

struct LinkedClipsStatusIconView: View {
    var body: some View {
        Image(nsImage: LinkedClipsStatusIcon.image)
            .renderingMode(.template)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}
