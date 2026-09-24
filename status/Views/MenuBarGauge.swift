import AppKit

/// Draws the menu bar gauge at any usage fraction (0...1) as an 18×18 pt template image.
/// Use instead of the fixed MenuBarIcon-XX assets when you want a continuous gauge.
enum MenuBarGauge {
    static func image(usage: Double) -> NSImage {
        let p = min(max(usage, 0), 1)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 6.75
            let start: CGFloat = 135, sweep: CGFloat = 270

            func arc(to fraction: CGFloat) -> NSBezierPath {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: start, endAngle: start + sweep * fraction, clockwise: false)
                path.lineWidth = 1.9
                path.lineCapStyle = .round
                return path
            }

            NSColor.black.withAlphaComponent(0.3).setStroke()
            arc(to: 1).stroke()
            if p > 0 {
                NSColor.black.setStroke()
                arc(to: CGFloat(p)).stroke()
            }

            let spark = NSBezierPath()
            spark.move(to: NSPoint(x: 9, y: 6))
            spark.curve(to: NSPoint(x: 12, y: 9), controlPoint1: NSPoint(x: 9.2, y: 8), controlPoint2: NSPoint(x: 10, y: 8.8))
            spark.curve(to: NSPoint(x: 9, y: 12), controlPoint1: NSPoint(x: 10, y: 9.2), controlPoint2: NSPoint(x: 9.2, y: 10))
            spark.curve(to: NSPoint(x: 6, y: 9), controlPoint1: NSPoint(x: 8.8, y: 10), controlPoint2: NSPoint(x: 8, y: 9.2))
            spark.curve(to: NSPoint(x: 9, y: 6), controlPoint1: NSPoint(x: 8, y: 8.8), controlPoint2: NSPoint(x: 8.8, y: 8))
            spark.close()
            NSColor.black.setFill()
            spark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Token usage \(Int(p * 100)) percent"
        return image
    }
}
