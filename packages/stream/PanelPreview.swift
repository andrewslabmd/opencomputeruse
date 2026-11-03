import Foundation
import CoreGraphics

public enum InlinePreviewGeometry {
    public static let maximumHeight: CGFloat = 220
    public static let cursorScale: CGFloat = 0.6
    public static func aspect(windowSize: CGSize) -> CGFloat {
        guard windowSize.width > 0, windowSize.height > 0 else { return 1 }
        return windowSize.width / windowSize.height
    }
    public static func size(width: CGFloat, windowSize: CGSize) -> CGSize {
        CGSize(width: max(0, width), height: min(maximumHeight, max(0, width) / aspect(windowSize: windowSize)))
    }
    public static func cursorCanvas(viewSize: CGSize) -> CGSize {
        CGSize(width: viewSize.width / cursorScale, height: viewSize.height / cursorScale)
    }
    /// The cursor NSView scales its coordinate space by 60%, independently of
    /// the target window's aspect-fit transform. Its tip still lands on the video.
    public static func cursorPoint(window: CGPoint, windowSize: CGSize, viewSize: CGSize) -> CGPoint? {
        guard let point = StreamPoints.viewPoint(window: window, windowSize: windowSize, viewSize: viewSize) else { return nil }
        return CGPoint(x: point.x / cursorScale, y: point.y / cursorScale)
    }
}

/// The panel's sole subscription owner. Host refreshes and SwiftUI relayouts
/// must not duplicate subscriptions, or retain watch intent after closing.
public final class PanelSubscriptions {
    private let subscribe: (StreamSubscription) -> Void
    private let unsubscribe: (String) -> Void
    public private(set) var active = Set<String>()
    public init(subscribe: @escaping (StreamSubscription) -> Void, unsubscribe: @escaping (String) -> Void) {
        self.subscribe = subscribe; self.unsubscribe = unsubscribe
    }
    public func update(isOpen: Bool, agents: Set<String>) {
        let desired = isOpen ? agents : []
        for id in active.subtracting(desired).sorted() { unsubscribe(id) }
        for id in desired.subtracting(active).sorted() { subscribe(.init(agent: id, max_fps: 15, codec: .h264)) }
        active = desired
    }
}
