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
