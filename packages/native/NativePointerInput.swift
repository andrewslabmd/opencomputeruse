import AppKit
import Foundation

// Process-directed left-button input bound to one retained window. Web content
// (Chromium/Electron) ignores posted mouse events without a window number; the
// public NSEvent constructor records it. For another process's window, NSEvent
// keeps the location as given and the receiving AppKit reads it relative to
// that window, so the location is window-local (top-left, points). Nothing is
// sent to the Window Server's HID stream: the cursor does not move and no other
// process receives the event. The receiver only accepts it while logically
// active, which the workflow's owned background-focus lease provides.

/// A left-button gesture: a click (one point, no hold; up to three in a row for
/// double/triple clicks), a press held in place (one point, a duration) or a
/// drag/swipe (two points, moving over a duration). Modifiers are flags on the
/// gesture's own events; no modifier key is pressed.
struct NativePointerGesture: Equatable {
    var points: [CGPoint]
    var duration: TimeInterval = 0
    var clickCount: Int = 1
    var modifiers: CGEventFlags = []
    static let maximumDuration: TimeInterval = 5
    static let modifierNames: [(CGEventFlags, String)] = [(.maskControl, "Ctrl"), (.maskAlternate, "Option"), (.maskShift, "Shift"), (.maskCommand, "Cmd")]
    var name: String {
        let base = points.count > 1 ? "LeftDrag" : duration > 0 ? "LeftLongPress"
            : clickCount == 2 ? "LeftDoubleClick" : clickCount == 3 ? "LeftTripleClick" : "LeftClick"
        return (Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.1) + [base]).joined(separator: "+")
    }
    var behavior: String { points.count > 1 ? "pointer_drag" : duration > 0 ? "pointer_long_press" : "pointer_click" }
}

extension NativeInputPlan {
    static func click(at point: CGPoint, window: CGWindowID, frame: CGRect, primaryScreenHeight: CGFloat) throws -> NativeInputPlan {
        try pointer(.init(points: [point]), window: window, frame: frame, primaryScreenHeight: primaryScreenHeight)
    }

    static func pointer(_ gesture: NativePointerGesture, window: CGWindowID, frame: CGRect, primaryScreenHeight: CGFloat) throws -> NativeInputPlan {
        guard window != 0, frame.width > 0, frame.height > 0, primaryScreenHeight > 0,
              (1...2).contains(gesture.points.count), gesture.points.allSatisfy({ frame.contains($0) }) else {
            throw NativeInteractionFailure(code: "pointer_target_unavailable", message: "The pointer point is outside the retained window. No pointer input was sent.")
        }
        guard gesture.duration.isFinite, gesture.duration >= 0, gesture.duration <= NativePointerGesture.maximumDuration else {
            throw NativeInteractionFailure(code: "invalid_pointer_duration", message: "Pointer durations must be between 0 and 5 seconds. No pointer input was sent.")
        }
        guard (1...3).contains(gesture.clickCount), gesture.clickCount == 1 || (gesture.points.count == 1 && gesture.duration == 0) else {
            throw NativeInteractionFailure(code: "invalid_click_count", message: "Only a plain click can be repeated, at most three times. No pointer input was sent.")
        }
        guard gesture.modifiers.isSubset(of: NativeInputPlan.modifierMask) else {
            throw NativeInteractionFailure(code: "invalid_modifier", message: "Unsupported pointer modifier. No pointer input was sent.")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw NativeInteractionFailure(code: "pointer_input_unavailable", message: "Native pointer events could not be created.")
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, pressure: Float, clickCount: Int = 1, offset: TimeInterval = 0) throws -> CGEvent {
            // NSEvent flips y against the primary screen when converting to CGEvent.
            let location = NSPoint(x: point.x - frame.minX, y: primaryScreenHeight - (point.y - frame.minY))
            guard let event = NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(gesture.modifiers.rawValue)), timestamp: timestamp + offset,
                    windowNumber: Int(window), context: nil, eventNumber: clickCount, clickCount: clickCount, pressure: pressure)?.cgEvent else {
                throw NativeInteractionFailure(code: "pointer_input_unavailable", message: "Native pointer events could not be created.")
            }
            // A private source: no shared HID button or modifier state. The
            // receiver reads modifiers from the event itself.
            event.setSource(source)
            event.flags = gesture.modifiers
            return event
        }
        let start = gesture.points[0], end = gesture.points.last!
        if gesture.clickCount > 1 {
            // Each press carries its position in the series, as AppKit counts
            // it: down/up 1, down/up 2 (double), down/up 3 (triple).
            let events = try (1...gesture.clickCount).flatMap { count in
                let offset = Double(count - 1) * 0.08
                return [try event(.leftMouseDown, start, pressure: 1, clickCount: count, offset: offset),
                        try event(.leftMouseUp, start, pressure: 0, clickCount: count, offset: offset + 0.02)]
            }
            // Give the receiver a distinct press/release and time to handle the
            // first click before the next. The dispatcher updates timestamps at
            // posting and revalidates after each wait; no semantic open/retry.
            let delays = events.indices.map { $0 == 0 ? 0.0 : ($0 % 2 == 1 ? 0.02 : 0.06) }
            return .init(source: source, events: events, kind: gesture.behavior, textUnits: nil, delays: delays)
        }
        var events = [try event(.leftMouseDown, start, pressure: 1)]
        var delays: [TimeInterval] = [0]
        if gesture.points.count > 1 {
            // Intermediate moves about every 16 ms, so the receiver tracks the
            // drag as a continuous movement with the requested speed.
            let steps = max(2, min(120, Int((gesture.duration / 0.016).rounded())))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                events.append(try event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), pressure: 1))
                delays.append(gesture.duration / Double(steps))
            }
            delays.append(0)
        } else {
            delays.append(gesture.duration)
        }
        events.append(try event(.leftMouseUp, end, pressure: 0))
        let kind = gesture.behavior
        // A plain click keeps its original back-to-back dispatch.
        return .init(source: source, events: events, kind: kind, textUnits: nil, delays: gesture.points.count == 1 && gesture.duration == 0 ? [] : delays)
    }
}
