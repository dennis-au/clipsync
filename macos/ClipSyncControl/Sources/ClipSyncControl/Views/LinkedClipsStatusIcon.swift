import SwiftUI

struct LinkedClipsStatusIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 18
            let stroke = StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round)
            let rear = CGRect(x: 2.6 * scale, y: 5.3 * scale, width: 9.6 * scale, height: 10.1 * scale)
            let front = CGRect(x: 6.1 * scale, y: 2.3 * scale, width: 9.6 * scale, height: 10.1 * scale)

            context.stroke(
                Path(roundedRect: rear, cornerRadius: 1.8 * scale),
                with: .color(.primary),
                style: stroke
            )
            context.stroke(
                Path(roundedRect: front, cornerRadius: 1.8 * scale),
                with: .color(.primary),
                style: stroke
            )

            var connector = Path()
            connector.move(to: CGPoint(x: 7.4 * scale, y: 9.1 * scale))
            connector.addLine(to: CGPoint(x: 11.1 * scale, y: 9.1 * scale))
            context.stroke(connector, with: .color(.primary), style: stroke)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
