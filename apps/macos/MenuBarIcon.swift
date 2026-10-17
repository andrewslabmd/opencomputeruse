import AppKit

// The menu-bar icon, matching the app icon: two soft ripple discs with the
// Phosphor navigation-arrow (see THIRD_PARTY_NOTICES.md) clicking at their
// center. 20 x 20 points, so the arrow carries the same weight as
// neighboring menu-bar icons.
// Idle: a template image the system tints for light and dark menu bars (the
// discs' lower opacity shows as a lighter tone).
// Working (an agent holds an app, thinking or acting): the discs take that
// agent's cursor color and a ripple pulses outward from the tip; the arrow
// follows the menu bar's text color.
enum MenuBarIcon {
    static let period: TimeInterval = 1.4
    private static let arrow = NSImage(data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><path fill=\"#000\" d=\"\(AgentCursorView.arrowPath)\"/></svg>".utf8))

    /// `color` nil draws the idle template icon; `phase` (0..<1) is the ripple's progress.
    static func make(color: NSColor? = nil, phase: CGFloat = 0) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let tip = CGPoint(x: 6.4, y: rect.height - 6.4)      // ripple center = arrow tip
            func disc(_ radius: CGFloat, _ fill: NSColor) {
                fill.setFill()
                NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            if let color {
                disc(6.0, color.withAlphaComponent(0.3))
                disc(3.4, color.withAlphaComponent(0.95))
                // The ripple: a ring growing from the inner disc to the edge, fading out.
                let radius = 3.4 + (5.75 - 3.4) * phase
                color.withAlphaComponent(0.9 * (1 - phase)).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 1.3; ring.stroke()
            } else {
                disc(6.0, NSColor.black.withAlphaComponent(0.35))
                disc(3.4, NSColor.black.withAlphaComponent(0.6))
            }
            // The arrow's apex sits 45/256 of its box from the top-left corner.
            let size: CGFloat = 16, apex = 45.0 / 256 * size
            let box = NSRect(x: tip.x - apex, y: tip.y + apex - size, width: size, height: size)
            // A thin gap between the arrow and the discs keeps it crisp.
            arrow?.draw(in: box.insetBy(dx: -0.9, dy: -0.9), from: .zero, operation: .destinationOut, fraction: 1, respectFlipped: true, hints: nil)
            if color == nil {
                arrow?.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                // The menu bar's text color, resolved for its current appearance.
                let tinted = NSImage(size: box.size, flipped: false) { r in
                    arrow?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSColor.labelColor.set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: box)
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = color == nil ? "Open Computer Use" : "Open Computer Use: an agent is working"
        return image
    }
}
