import Foundation
import CoreGraphics

/// Presentation only: it never requests permission or changes the watched app.
public enum PiPState: Equatable, CaseIterable {
    case live, minimized, hidden, closed, noTarget, stopped, unavailable, noPermission, disconnected

    public init(target: StreamTargetState?, end: StreamEndReason? = nil,
                stopped: Bool = false, noPermission: Bool = false) {
        if end == .disconnected { self = .disconnected; return }
        if stopped { self = .stopped; return }
        if noPermission { self = .noPermission; return }
        if let end {
            switch end {
            case .disconnected: self = .disconnected
            case .paused, .stopped, .capture_stopped_by_user: self = .stopped
            case .released, .unsubscribed: self = .noTarget
            case .error: self = .unavailable
            }
            return
        }
        switch target {
        case .live?: self = .live
        case .minimized?: self = .minimized
        case .hidden?: self = .hidden
        case .closed?: self = .closed
        case .idle?, nil: self = .noTarget
        case .hidden_from_capture?: self = .unavailable
        case .stopped?: self = .stopped
        case .no_permission?: self = .noPermission
        }
    }

    public var text: String? {
        switch self {
        case .live, .disconnected: return nil
        case .minimized: return "Minimized"
        case .hidden: return "Hidden"
        case .closed: return "Window closed"
        case .noTarget: return "Not working in an app"
        case .stopped: return "Stopped"
        case .unavailable: return "This window can't be shown."
        case .noPermission: return "Screen Recording is off"
        }
    }
    public var keepsLastFrame: Bool { self == .live || self == .minimized || self == .hidden }
    public var dimsLastFrame: Bool { self == .minimized || self == .hidden }
}

public enum PiPGeometry {
    public static let defaultWidth: CGFloat = 360
    public static let widthRange: ClosedRange<CGFloat> = 240...720
    public static let maximumHeight: CGFloat = 300

    /// The panel keeps the window's shape until the height cap; its content then
    /// aspect-fits, using exactly the same transform for the video and cursor.
    public static func size(width: CGFloat = defaultWidth, windowSize: CGSize) -> CGSize {
        let width = min(max(width, widthRange.lowerBound), widthRange.upperBound)
        guard windowSize.width > 0, windowSize.height > 0 else { return CGSize(width: width, height: maximumHeight) }
        return CGSize(width: width, height: min(maximumHeight, width * windowSize.height / windowSize.width))
    }
    public static func viewPoint(window: CGPoint, windowSize: CGSize, viewSize: CGSize) -> CGPoint? {
        StreamPoints.viewPoint(window: window, windowSize: windowSize, viewSize: viewSize)
    }
}
