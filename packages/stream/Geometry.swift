import CoreGraphics
import Foundation

public enum StreamPoints {
    /// All coordinates use a top-left origin; no backing-pixel scale is applied.
    public static func windowPoint(global: CGPoint, frame: StreamRect) -> CGPoint {
        CGPoint(x: global.x - frame.x, y: global.y - frame.y)
    }
    /// Returns nil when there is no drawable window or view area.
    public static func viewPoint(window: CGPoint, windowSize: CGSize, viewSize: CGSize) -> CGPoint? {
        guard windowSize.width > 0, windowSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale = min(viewSize.width / windowSize.width, viewSize.height / windowSize.height)
        return CGPoint(x: (viewSize.width - windowSize.width * scale) / 2 + window.x * scale,
                       y: (viewSize.height - windowSize.height * scale) / 2 + window.y * scale)
    }
}
