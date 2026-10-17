import ApplicationServices
import Foundation

// Geometry and execution share the same retained native identities. Capability
// information is obtained at the point of use, never while collecting a tree.
struct NativeInteractionNode {
    let id: String
    let role: String
    let subrole: String?
    let frame: CGRect?
    let children: [NativeInteractionNode]
    var offscreen: Bool = false
}

struct NativeInteractionFailure: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

enum NativeValidationPhase {
    case point, receiver, identity
    func matches(actual: CGRect, expected: CGRect, point: CGPoint, linked: Bool) -> Bool {
        if self == .identity { return true }
        return (self != .point || linked || actual.contains(point)) &&
            abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1 &&
            abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
    }
}

enum NativePointResolver {
    static func elementChain(root: NativeInteractionNode, elementID: String, allowOffscreen: Bool = false) throws -> [NativeInteractionNode] {
        var pending: [(NativeInteractionNode, [NativeInteractionNode])] = [(root, [])]
        while let (node, parents) = pending.popLast() {
            if node.id == elementID {
                guard !node.offscreen || allowOffscreen else { throw NativeInteractionFailure(code: "target_offscreen", message: "The retained control is offscreen.") }
                return [node] + parents.reversed()
            }
            pending.append(contentsOf: node.children.map { ($0, parents + [node]) })
        }
        throw NativeInteractionFailure(code: "native_target_changed", message: "The retained control is absent from this window.")
    }

    static func chain(root: NativeInteractionNode, nativeHitIDs: [String], point: CGPoint) throws -> [NativeInteractionNode] {
        var nodes: [String: NativeInteractionNode] = [:]
        var parents: [String: String] = [:]
        func index(_ node: NativeInteractionNode, parent: String?) {
            nodes[node.id] = node
            parents[node.id] = parent
            for child in node.children { index(child, parent: node.id) }
        }
        index(root, parent: nil)
        guard let hitID = nativeHitIDs.first, let hit = nodes[hitID],
              nativeHitIDs.allSatisfy({ nodes[$0] != nil }) else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The native hit is absent from the observation. Observe again.")
        }
        // Validate ancestry rather than trusting a serialized list of IDs.
        for pair in zip(nativeHitIDs, nativeHitIDs.dropFirst()) {
            var parent = parents[pair.0]
            while let id = parent, id != pair.1 { parent = parents[id] }
            guard parent == pair.1 else {
                throw NativeInteractionFailure(code: "native_target_changed", message: "The native target ancestry changed. Observe again.")
            }
        }
        var hits: [NativeInteractionNode] = []
        func collect(_ n: NativeInteractionNode) {
            if !n.offscreen, let frame = n.frame, frame.contains(point) { hits.append(n) }
            for child in n.children { collect(child) }
        }
        collect(hit)
        func ancestor(_ a: String, of b: String) -> Bool {
            var parent = parents[b]
            while let id = parent { if id == a { return true }; parent = parents[id] }
            return false
        }
        func encloses(_ a: CGRect, _ b: CGRect) -> Bool {
            a.minX <= b.minX && a.minY <= b.minY && a.maxX >= b.maxX && a.maxY >= b.maxY
        }
        let precise = hits.filter { a in
            !hits.contains { b in
                guard a.id != b.id, let af = a.frame, let bf = b.frame else { return false }
                return encloses(af, bf) && (!encloses(bf, af) || ancestor(a.id, of: b.id))
            }
        }
        guard precise.count <= 1 else {
            throw NativeInteractionFailure(code: "ambiguous_target", message: "Overlapping controls cannot be distinguished at this point. Choose another point or observe again.")
        }
        guard let target = precise.first else { return [] }
        var result = [target]
        var parent = parents[target.id]
        while let id = parent, let node = nodes[id] {
            // Frame-less layout ancestors can be owners of selection attributes;
            // framed ancestors must also contain the point.
            if node.frame == nil || node.frame!.contains(point) { result.append(node) }
            parent = parents[id]
        }
        return result
    }
}

enum NativeCallOutcome {
    case returned(AXError)
    case pending
}

protocol NativeInteractionAccess {
    func validate(_ node: NativeInteractionNode) throws
    func validateRelated(_ node: NativeInteractionNode, owner: NativeInteractionNode) throws
    func refreshAfterMutation(_ node: NativeInteractionNode) throws -> NativeInteractionNode
    func read(_ id: String, _ attribute: String) throws -> CFTypeRef?
    func ownsKeyboardFocus(_ id: String) throws -> Bool
    func inputText(_ id: String, _ text: String) throws -> String
    /// Window-bound, process-directed left-button input to the receiver's window.
    func pointerGesture(_ id: String, _ gesture: NativePointerGesture) throws -> String
    /// Whether the app's keyboard focus is one of these elements, or nothing.
    func keyboardFocusWithin(_ ids: [String]) throws -> Bool
    /// Text as process-directed keystrokes while focus stays within these elements.
    func keyboardText(_ id: String, _ text: String, within ids: [String]) throws -> String
    /// Whether the target app is logically active (real or owned background activation).
    func appActive() throws -> Bool
    func parameterized(_ id: String, _ attribute: String, _ parameter: CFTypeRef) throws -> CFTypeRef?
    func scrollBar(_ owner: NativeInteractionNode, vertical: Bool) throws -> NativeInteractionNode?
    func write(_ id: String, _ attribute: String, _ value: CFTypeRef) throws -> AXError
    func perform(_ id: String, _ action: String) throws -> NativeCallOutcome
    func element(_ id: String) throws -> CFTypeRef
    /// Whether a live element read back from the app is the retained control, or the
    /// same control rebuilt by the app (same role, geometry and visible text).
    func sameControl(_ element: CFTypeRef, as id: String) throws -> Bool
    func actionNames(_ id: String) throws -> [String]
    func canWrite(_ id: String, _ attribute: String) throws -> Bool
    func capabilities(_ id: String) throws -> NativeSupportedOperations
}

extension NativeInteractionAccess {
    func refreshAfterMutation(_ node: NativeInteractionNode) throws -> NativeInteractionNode {
        try validate(node); return node
    }
    func validateControl(_ node: NativeInteractionNode) throws {
        try validate(node)
        if (try read(node.id, "AXEnabled") as? NSNumber)?.boolValue == false {
            throw NativeInteractionFailure(code: "target_disabled", message: "The operation's \(node.role) control is disabled.")
        }
    }
}

struct NativeSupportedOperations: Encodable {
    let id: String
    let actions: [String]
    let writableAttributes: [String]
}

struct NativeOperationRecord: Encodable {
    let receiver_id: String
    let kind: String
    let name: String
    let native_error: Int32?
    let outcome: String
}

struct NativeInteractionResult: Encodable {
    var status: String
    var behavior: String
    var element_id: String?
    var operations: [NativeOperationRecord] = []
    var code: String?
    var error: String?
    var supported: [NativeSupportedOperations]?
    // This describes native API acceptance, never the user's semantic outcome.
    var effect: String? = nil
    var submit_ready: Bool = false
    var state_check: NativeStateCheck? = nil
    var text_check: NativeTextCheck? = nil
    var input_trace_ids: [String]? = nil
    var selection_check: NativeSelectionCheck? = nil
}

/// An accepted selection the immediate readback could not show yet (apps that
/// navigate on selection update it later). Confirmed against the fresh capture.
struct NativeSelectionCheck: Encodable {
    let receiver_id: String
}

struct NativeTextCheck: Encodable {
    let receiver_id: String
    let expected: String?
    let submit: Bool
}

struct NativeStateCheck: Encodable {
    let receiver_id: String
    let property: String
    let comparison: String
    let before: Double?
    let matched_effect: String
    var expected: Double? = nil
    var tolerance: Double? = nil
}

struct NativeInteractionAction {
    let kind: String
    let point: CGPoint
    var destination: CGPoint?
    var text: String = ""
    var replace: Bool = false
    var submit: Bool = false
    var direction: String = "down"
    var amount: Int = 3
    var pointer: Bool = false
    /// Seconds a pointer press is held (long_press) or a drag takes.
    var duration: TimeInterval = 0
    /// Clicks in a row (double/triple) and modifiers; both are pointer-only.
    var clickCount: Int = 1
    var modifiers: CGEventFlags = []
    /// perform_action: the advertised action to perform; nil lists them.
    var actionName: String? = nil
}

struct NativeInteractionExecutor {
    let access: any NativeInteractionAccess
    static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXDisclosureTriangle", "AXLink"]
    static let adjustable: Set<String> = ["AXSlider", "AXScrollBar"]
    static let menuOpeners: Set<String> = ["AXPopUpButton", "AXMenuButton"]

    func execute(_ action: NativeInteractionAction, chain: [NativeInteractionNode]) throws -> NativeInteractionResult {
        var result = NativeInteractionResult(status: "no_effect", behavior: "no_effect", element_id: chain.first?.id)
        do {
            guard !chain.isEmpty else { return result }
            // Identity/geometry applies to the whole path. Enabled state applies
            // to operation receivers, not inert page/section/layout objects.
            for node in chain {
                try access.validate(node)
                if node.role == "AXWindow" { try access.validateControl(node) }
            }
            func record(_ id: String, kind: String, name: String, outcome: NativeCallOutcome) throws -> Bool {
                switch outcome {
                case .pending:
                    result.operations.append(NativeOperationRecord(receiver_id: id, kind: kind, name: name, native_error: nil, outcome: "pending"))
                    result.status = "pending"; result.effect = "native_call_pending"
                    return true
                case .returned(let error):
                    result.operations.append(NativeOperationRecord(receiver_id: id, kind: kind, name: name, native_error: error.rawValue, outcome: error == .success ? "accepted" : "returned_error"))
                    if error == .success { result.status = "completed"; return true }
                    // An attribute error returned by PerformAction is NOT proof
                    // that no mutation happened (real scroll providers do this).
                    let unsupported = kind == "action" && error == .actionUnsupported
                    if unsupported { return false }
                    // A timeout/invalid element/other uncertain error is not evidence
                    // that nothing happened. Never try another target after it.
                    throw NativeInteractionFailure(code: "native_operation_uncertain", message: "\(name) returned AXError \(error.rawValue). No further operation was sent to this target.")
                }
            }
            func perform(_ node: NativeInteractionNode, _ name: String, behavior: String) throws -> Bool {
                try access.validateControl(node)
                result.behavior = behavior; result.element_id = node.id
                return try record(node.id, kind: "action", name: name, outcome: access.perform(node.id, name))
            }
            func write(_ receiver: NativeInteractionNode, _ name: String, _ value: CFTypeRef, target: NativeInteractionNode, behavior: String) throws -> Bool {
                try access.validateControl(receiver); try access.validate(target)
                if Self.pressable.contains(target.role) || Self.editable.contains(target.role) || Self.adjustable.contains(target.role) || ["AXRow", "AXTab"].contains(target.role) {
                    try access.validateControl(target)
                }
                guard try access.canWrite(receiver.id, name) else { return false }
                result.behavior = behavior; result.element_id = target.id
                return try record(receiver.id, kind: "attribute", name: name, outcome: .returned(access.write(receiver.id, name, value)))
            }
            // Background activation raises the target's window, so it is requested
            // only for operations an inactive app ignores: window-bound pointer
            // input and opening menus. Nothing is dispatched before this check;
            // the caller activates and repeats the same request once.
            func requireActivation() throws {
                if try access.appActive() { return }
                // Only before any dispatch can the caller safely activate and repeat.
                guard result.operations.isEmpty else { return }
                throw NativeInteractionFailure(code: "app_activation_required", message: "This operation needs the app's background activation. Nothing was sent.")
            }
            func supportedFailure(_ code: String, _ message: String) throws -> NativeInteractionResult {
                result.status = "failed"; result.code = code; result.error = message
                result.effect = result.operations.isEmpty ? "not_attempted" : "change_possible"
                result.supported = try chain.map { try access.capabilities($0.id) }
                return result
            }
            func focus(_ node: NativeInteractionNode) throws -> Bool {
                try access.validateControl(node)
                if try access.ownsKeyboardFocus(node.id) { return true }
                // AXFocused on an editor is local to its window in AppKit. It
                // does not necessarily make that window the app's key window.
                // Use the native owning window, never infer ownership by title
                // or move a containing document out from under a modal sheet.
                if let windowIndex = chain.firstIndex(where: { $0.role == "AXWindow" }),
                   !chain[..<windowIndex].contains(where: { ["AXSheet", "AXMenu"].contains($0.role) }) {
                    let window = chain[windowIndex]
                    if try !access.ownsKeyboardFocus(window.id) {
                        if try write(window, "AXMain", kCFBooleanTrue, target: node, behavior: "focus_window") {
                            guard try access.ownsKeyboardFocus(window.id) else { return false }
                        }
                    }
                }
                guard try write(node, "AXFocused", kCFBooleanTrue, target: node, behavior: "focus") else { return false }
                return try access.ownsKeyboardFocus(node.id)
            }
            func positionCaret(_ node: NativeInteractionNode) throws -> NativeInteractionResult {
                guard try access.canWrite(node.id, "AXSelectedTextRange") else {
                    return try supportedFailure("text_position_unavailable", "The control does not expose a writable insertion position.")
                }
                var point = action.point
                guard let parameter = AXValueCreate(.cgPoint, &point),
                      let raw = try access.parameterized(node.id, "AXRangeForPosition", parameter),
                      CFGetTypeID(raw) == AXValueGetTypeID() else {
                    return try supportedFailure("text_position_unavailable", "The editor did not expose a text position for the requested point.")
                }
                var range = CFRange()
                guard AXValueGetType(unsafeBitCast(raw, to: AXValue.self)) == .cfRange,
                      AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range), range.location >= 0 else {
                    return try supportedFailure("text_position_unavailable", "The editor returned an invalid text position.")
                }
                range.length = 0
                guard try focus(node) else { return try supportedFailure("text_focus_unavailable", "The editor could not be focused through Accessibility.") }
                guard let value = AXValueCreate(.cfRange, &range),
                      try write(node, "AXSelectedTextRange", value, target: node, behavior: "position_caret") else {
                    return try supportedFailure("text_position_unavailable", "The editor does not allow setting its insertion position.")
                }
                let actual = try access.read(node.id, "AXSelectedTextRange")
                var actualRange = CFRange()
                guard let actual, CFGetTypeID(actual) == AXValueGetTypeID(),
                      AXValueGetValue(unsafeBitCast(actual, to: AXValue.self), .cfRange, &actualRange),
                      actualRange.location == range.location, actualRange.length == 0 else {
                    result.status = "failed"; result.code = "text_position_not_applied"
                    result.error = "The editor's insertion position did not match the requested position."
                    return result
                }
                result.effect = "caret_positioned"; return result
            }
            func adjust(_ node: NativeInteractionNode, at point: CGPoint) throws -> Bool {
                guard let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
                var scrollOwner: NativeInteractionNode?
                if node.role == "AXScrollBar", let owner = chain.first(where: { $0.role == "AXScrollArea" }) {
                    for vertical in [true, false] {
                        if let linked = try access.scrollBar(owner, vertical: vertical), linked.id == node.id {
                            try access.validateRelated(node, owner: owner); scrollOwner = owner; break
                        }
                    }
                }
                guard let bounds = try numericBounds(node, nativeScrollOwner: scrollOwner) else { return false }
                let minimum = bounds.0, maximum = bounds.1
                guard minimum.isFinite, maximum.isFinite, maximum >= minimum else { return false }
                let fraction = frame.height > frame.width
                    ? (node.role == "AXScrollBar" ? (point.y - frame.minY) : (frame.maxY - point.y)) / frame.height
                    : (point.x - frame.minX) / frame.width
                let value = minimum + (maximum - minimum) * min(1, max(0, fraction))
                let before = (try access.read(node.id, "AXValue") as? NSNumber)?.doubleValue
                guard try write(node, "AXValue", NSNumber(value: value), target: node, behavior: "adjust") else { return false }
                let tolerance = max(1e-9, (maximum - minimum) * 1e-6)
                result.state_check = NativeStateCheck(receiver_id: node.id, property: "value", comparison: "equals",
                    before: before, matched_effect: "value_matches", expected: value, tolerance: tolerance)
                let actual = (try access.read(node.id, "AXValue") as? NSNumber)?.doubleValue
                result.effect = actual.map { abs($0-value) <= tolerance } == true ? "value_matches" : "value_unconfirmed"
                return true
            }
            func numericBounds(_ node: NativeInteractionNode, nativeScrollOwner: NativeInteractionNode? = nil) throws -> (Double, Double)? {
                let minimum = (try access.read(node.id, "AXMinValue") as? NSNumber)?.doubleValue
                let maximum = (try access.read(node.id, "AXMaxValue") as? NSNumber)?.doubleValue
                if let low = minimum, let high = maximum,
                   low.isFinite, high.isFinite, high > low { return (low, high) }
                // Native scrollers linked by AXVertical/HorizontalScrollBar use
                // relative position, unlike arbitrary role=scrollbar/slider UI.
                // WebKit AccessibilityScrollbar::valueForRange/setValue implement
                // this contract but inherited min/max accessors return 0/0.
                // Require the validated native ownership link and a finite position;
                // never override an explicit nondegenerate custom range.
                guard node.role == "AXScrollBar", nativeScrollOwner?.role == "AXScrollArea",
                      (minimum == nil || minimum == 0),
                      (maximum == nil || maximum == 0 || maximum == 1),
                      let position = (try access.read(node.id, "AXValue") as? NSNumber)?.doubleValue,
                      position.isFinite, (0...1).contains(position) else { return nil }
                return (0, 1)
            }
            // Window-bound, process-directed pointer input to the validated
            // receiver. It lands at the requested point inside it; for an element
            // reference without a contained point, at its centre.
            func pointerGesture(_ node: NativeInteractionNode, _ gesture: NativePointerGesture) throws -> NativeInteractionResult {
                try access.validate(node)
                try requireActivation()
                result.input_trace_ids = [try access.pointerGesture(node.id, gesture)]
                result.element_id = node.id; result.behavior = gesture.behavior; result.status = "sent"; result.effect = gesture.behavior + "_sent"
                result.operations.append(.init(receiver_id: node.id, kind: "pointer", name: gesture.name, native_error: nil, outcome: "dispatched"))
                return result
            }
            func pointerPoint(_ node: NativeInteractionNode) -> CGPoint {
                node.frame.map { $0.contains(action.point) ? action.point : CGPoint(x: $0.midX, y: $0.midY) } ?? action.point
            }
            func pointerClick(_ node: NativeInteractionNode) throws -> NativeInteractionResult {
                try pointerGesture(node, .init(points: [pointerPoint(node)], clickCount: action.clickCount, modifiers: action.modifiers))
            }
            // Surfaces that accept keys but expose no editor (canvases, remote and
            // device screens, games). Keys go to the app's keyboard focus, so they
            // are sent only while that focus is the surface at this point, one of
            // its containers, or nothing; never to a control elsewhere in the app.
            func keyboardSurfaceText() throws -> NativeInteractionResult {
                let target = chain[0]
                if Self.pressable.contains(target.role) || Self.adjustable.contains(target.role) || ["AXRow", "AXTab"].contains(target.role) {
                    return try supportedFailure("target_not_editable", "No editable control exists at this point.")
                }
                guard !action.replace else {
                    return try supportedFailure("text_replace_unavailable", "Without an editable control the current text cannot be selected for replacement. Nothing was sent.")
                }
                guard !action.text.isEmpty || action.submit else { result.effect = "no_text"; return result }
                try requireActivation()
                if let window = chain.first(where: { $0.role == "AXWindow" }), try !access.ownsKeyboardFocus(window.id) {
                    guard try write(window, "AXMain", kCFBooleanTrue, target: target, behavior: "focus_window"),
                          try access.ownsKeyboardFocus(window.id) else {
                        return try supportedFailure("keyboard_target_unavailable", "The surface's window is not the app's keyboard window. No text was sent.")
                    }
                }
                let ids = chain.map(\.id)
                guard try access.keyboardFocusWithin(ids) else {
                    return try supportedFailure("keyboard_focus_elsewhere", "The app's keyboard focus is on a control outside this point, which would receive the keys. Click the surface first (input_method pointer), then type. No text was sent.")
                }
                result.input_trace_ids = [try access.keyboardText(target.id, action.text + (action.submit ? "\n" : ""), within: ids)]
                result.element_id = target.id; result.behavior = "keyboard_text"; result.status = "sent"
                result.effect = action.submit ? "keyboard_text_return_sent" : "keyboard_text_sent"
                result.operations.append(.init(receiver_id: target.id, kind: "keyboard", name: "KeyboardText", native_error: nil, outcome: "dispatched"))
                return result
            }
            if action.kind == "long_press" {
                guard action.duration > 0 else { return try supportedFailure("invalid_pointer_duration", "A long press needs a hold duration.") }
                return try pointerGesture(chain[0], .init(points: [pointerPoint(chain[0])], duration: action.duration))
            }
            if action.kind == "scroll_to_visible" {
                let node = chain[0]
                guard try access.actionNames(node.id).contains("AXScrollToVisible"),
                      try perform(node, "AXScrollToVisible", behavior: "scroll_to_visible") else {
                    return try supportedFailure("unsupported_native_action", "The target does not expose native scrolling into view.")
                }
                return result
            }
            if action.kind == "open" {
                for node in chain {
                    if try access.actionNames(node.id).contains("AXOpen"),
                       try perform(node, "AXOpen", behavior: "open") { return result }
                }
                return try supportedFailure("unsupported_native_action", "The target does not expose native opening.")
            }
            // Any action the exact target advertises (AXShowMenu, AXIncrement,
            // an app's custom actions). Only that element receives it, never a
            // container; without a name nothing is sent and the advertised
            // actions of the target and its containers are returned.
            if action.kind == "perform_action" {
                let node = chain[0]
                guard let name = action.actionName else {
                    result.status = "completed"; result.behavior = "list_actions"; result.effect = "actions_listed"
                    result.supported = try chain.map { try access.capabilities($0.id) }
                    return result
                }
                guard try access.actionNames(node.id).contains(name) else {
                    return try supportedFailure("unsupported_native_action", "The target does not advertise \(name). Its advertised actions are in supported.")
                }
                if name == "AXShowMenu" || (name == "AXPress" && Self.menuOpeners.contains(node.role)) { try requireActivation() }
                // A press keeps the press behavior, so web presses are confirmed the same way.
                guard try perform(node, name, behavior: name == "AXPress" ? "press" : "perform_action") else {
                    return try supportedFailure("unsupported_native_action", "The target rejected \(name) as unsupported.")
                }
                return result
            }
            if action.kind == "select_text" {
                guard let node = chain.first(where: { Self.editable.contains($0.role) }),
                      let text = try access.read(node.id, "AXValue") as? String, !action.text.isEmpty else {
                    return try supportedFailure("text_selection_unavailable", "Exact selection requires an editable control with readable text.")
                }
                let ns = text as NSString, first = ns.range(of: action.text, options: .literal)
                guard first.location != NSNotFound else { return try supportedFailure("text_not_found", "The requested text is absent from this control.") }
                let remaining = NSRange(location: first.location + 1, length: ns.length - first.location - 1)
                guard ns.range(of: action.text, options: .literal, range: remaining).location == NSNotFound else {
                    return try supportedFailure("text_ambiguous", "The requested substring occurs more than once.")
                }
                var range = CFRange(location: first.location, length: first.length)
                guard let value = AXValueCreate(.cfRange, &range),
                      try write(node, "AXSelectedTextRange", value, target: node, behavior: "select_text") else {
                    return try supportedFailure("text_selection_unavailable", "The control does not support setting its text selection.")
                }
                var actual = CFRange()
                guard let raw = try access.read(node.id, "AXSelectedTextRange"), CFGetTypeID(raw) == AXValueGetTypeID(),
                      AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &actual), actual.location == range.location, actual.length == range.length else {
                    return try supportedFailure("text_selection_not_applied", "The control did not retain the requested text range.")
                }
                guard let current = try access.read(node.id, "AXValue") as? String,
                      actual.location >= 0, actual.length >= 0, actual.location + actual.length <= (current as NSString).length,
                      (current as NSString).substring(with: NSRange(location: actual.location, length: actual.length)) == action.text else {
                    return try supportedFailure("text_selection_changed", "The selected control's text changed during selection.")
                }
                result.effect = "selection_matches"; return result
            }
            if action.kind == "input_text" {
                guard let node = chain.first(where: { Self.editable.contains($0.role) || $0.subrole == "AXSearchField" }) else {
                    return try keyboardSurfaceText()
                }
                guard try focus(node) else { return try supportedFailure("text_focus_unavailable", "The editor does not own the app's keyboard focus.") }
                let current = try access.read(node.id, "AXValue") as? String
                var range = CFRange()
                var expected: String?
                if action.replace {
                    guard let current else { return try supportedFailure("text_selection_unavailable", "The target's complete text range is unavailable.") }
                    range = CFRange(location:0,length:current.utf16.count)
                    guard let value = AXValueCreate(.cfRange,&range),
                          try write(node,"AXSelectedTextRange",value,target:node,behavior:"select_text") else {
                        return try supportedFailure("text_selection_unavailable", "The target does not expose a writable text selection.")
                    }
                    var actual=CFRange()
                    guard let raw=try access.read(node.id,"AXSelectedTextRange"),CFGetTypeID(raw)==AXValueGetTypeID(),
                          AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cfRange,&actual),
                          actual.location==range.location,actual.length==range.length else {
                        return try supportedFailure("text_selection_not_applied", "The editor did not retain its complete text selection.")
                    }
                    expected=action.text
                } else if let current,let raw=try access.read(node.id,"AXSelectedTextRange"),CFGetTypeID(raw)==AXValueGetTypeID(),
                          AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cfRange,&range) {
                    expected=Self.replacingSelection(current,range:range,text:action.text)?.text
                }
                try access.validateControl(node)
                let dispatch = !action.text.isEmpty || range.length > 0
                if dispatch { result.input_trace_ids = [try access.inputText(node.id,action.text)] }
                result.element_id=node.id;result.behavior="text_input";result.status="sent";result.effect="text_input_sent"
                if dispatch { result.operations.append(.init(receiver_id:node.id,kind:"keyboard",name:"TextInput",native_error:nil,outcome:"dispatched")) }
                result.text_check=NativeTextCheck(receiver_id:node.id,expected:expected,submit:action.submit)
                return result
            }
            if action.kind == "confirm" {
                guard let node=chain.first(where:{Self.editable.contains($0.role)||$0.subrole=="AXSearchField"}) else {
                    return try supportedFailure("target_not_editable", "No editable control exists at this point.")
                }
                if try access.actionNames(node.id).contains("AXConfirm"),try perform(node,"AXConfirm",behavior:"submit") {return result}
                guard try focus(node) else {return try supportedFailure("submit_focus_unavailable", "The edited field does not own app keyboard focus.")}
                result.element_id=node.id;result.status="completed";result.behavior="submit";result.submit_ready=true
                return result
            }
            if action.kind == "type" {
                guard var node = chain.first(where: { Self.editable.contains($0.role) || $0.subrole == "AXSearchField" }) else {
                    return try supportedFailure("target_not_editable", "No editable control exists at this point.")
                }
                var expected: String?
                var cursor: Int?
                if action.replace {
                    expected = action.text; cursor = action.text.utf16.count
                    guard try write(node, "AXValue", action.text as CFString, target: node, behavior: "set_text") else {
                        return try supportedFailure("unsupported_native_action", "The editable control does not support replacing its value.")
                    }
                } else {
                    // Respect the selection, including Unicode UTF-16 ranges. This
                    // is insertion/replacement at the caret, not blind appending.
                    if let current = try access.read(node.id, "AXValue") as? String,
                       let rangeValue = try access.read(node.id, "AXSelectedTextRange"),
                       CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                        let value = unsafeBitCast(rangeValue, to: AXValue.self)
                        var range = CFRange()
                        if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
                           let edit = Self.replacingSelection(current, range: range, text: action.text) {
                            expected = edit.text; cursor = edit.cursor
                        }
                    }
                    if try write(node, "AXSelectedText", action.text as CFString, target: node, behavior: "insert_text") {
                        // The targeted selection setter has the intended caret semantics.
                    } else if let expected {
                        guard try write(node, "AXValue", expected as CFString, target: node, behavior: "set_text") else {
                            return try supportedFailure("unsupported_native_action", "The editable control does not support inserting text.")
                        }
                    } else {
                        return try supportedFailure("unsupported_native_action", "Text insertion needs a writable selection or a valid current selection range.")
                    }
                }
                // Text can resize/reposition its editor. Re-establish the same
                // native receiver before the cursor/focus followups, rather
                // than treating our own verified mutation as a stale point.
                node = try access.refreshAfterMutation(node)
                if let cursor {
                    var range = CFRange(location: cursor, length: 0)
                    if let value = AXValueCreate(.cfRange, &range) {
                        // A missing optional cursor setter does not erase a successful
                        // text change; its rejection is retained in the audit.
                        if try write(node, "AXSelectedTextRange", value, target: node, behavior: result.behavior) {
                            node = try access.refreshAfterMutation(node)
                        }
                    }
                }
                if let expected {
                    let actual = try access.read(node.id, "AXValue") as? String
                    result.effect = actual == expected ? "text_value_matches" : "text_value_unconfirmed"
                    if actual != expected {
                        result.status = "failed"; result.code = "text_change_unconfirmed"
                        result.error = "The editor's resulting text did not match the requested edit."
                        if action.submit { result.error! += " Return was not sent." }
                        return result
                    }
                }
                if action.submit {
                    if try access.actionNames(node.id).contains("AXConfirm") {
                        guard try perform(node, "AXConfirm", behavior: "confirm") else {
                            return try supportedFailure("native_submit_unavailable", "The control's native submit operation was rejected.")
                        }
                        return result
                    }
                    guard try focus(node) else { return try supportedFailure("submit_focus_unavailable", "Text changed, but the target could not be focused for Return.") }
                    result.behavior = "set_text"
                    result.submit_ready = true
                }
                return result
            }
            if action.kind == "right_click" {
                for node in chain {
                    if try access.actionNames(node.id).contains("AXShowMenu") {
                        try requireActivation()
                        if try perform(node, "AXShowMenu", behavior: "show_menu") { return result }
                    }
                }
                return try supportedFailure("unsupported_native_action", "The target does not support a context menu.")
            }
            if action.kind == "drag" {
                guard let destination = action.destination else { return try supportedFailure("invalid_drag", "A drag needs a destination.") }
                let adjustable = chain.first(where: { Self.adjustable.contains($0.role) })
                // A pointer drag (swipe) moves the button from the start point to the
                // destination in the receiver's window. Explicit, or for web content
                // without an adjustable control, like the pointer click.
                if action.pointer || (adjustable == nil && chain.contains(where: { $0.role == "AXWebArea" })) {
                    return try pointerGesture(chain[0], .init(points: [action.point, destination], duration: action.duration > 0 ? action.duration : 0.3))
                }
                guard let node = adjustable, try adjust(node, at: destination) else {
                    return try supportedFailure("unsupported_background_drag", "The target is not a writable control with a numeric range. Use input_method pointer to drag or swipe on the surface itself.")
                }
                return result
            }
            if action.kind == "scroll" {
                let names: [String: [String]] = ["up": ["AXScrollUpByPage", "AXPageUp"], "down": ["AXScrollDownByPage", "AXPageDown"], "left": ["AXScrollLeftByPage", "AXPageLeft"], "right": ["AXScrollRightByPage", "AXPageRight"]]
                guard let actions = names[action.direction] else { return try supportedFailure("invalid_scroll", "Unknown scroll direction.") }
                // Resolve the owning scroller, not every object under the point.
                guard let node = chain.first(where: { $0.role == "AXScrollArea" })
                    ?? chain.first(where: { ["AXList", "AXTable", "AXOutline"].contains($0.role) }) else {
                    return try supportedFailure("scroll_control_unavailable", "No scroll container was found at the requested point.")
                }
                func scrollPages() throws -> Bool {
                    for name in actions {
                        if try perform(node, name, behavior: "scroll") {
                            if result.status == "completed" {
                                for _ in 1..<max(1, Int(ceil(Double(action.amount) / 3))) {
                                    guard try perform(node, name, behavior: "scroll") else {
                                        throw NativeInteractionFailure(code: "scroll_incomplete", message: "A later scroll page was rejected; earlier pages may have completed.")
                                    }
                                    if result.status == "pending" { break }
                                }
                            }
                            return true
                        }
                    }
                    return false
                }
                // Prefer its explicitly associated, retained scrollbar. This is
                // an ownership link, never a search for an off-point sibling.
                if let bar = try access.scrollBar(node, vertical: ["up", "down"].contains(action.direction)),
                   try access.canWrite(bar.id, "AXValue") {
                    try access.validateRelated(bar, owner: node)
                    if (try access.read(bar.id, "AXEnabled") as? NSNumber)?.boolValue == false {
                        throw NativeInteractionFailure(code: "target_disabled", message: "The scroll control is disabled.")
                    }
                    guard let before = try access.read(bar.id, "AXValue") as? NSNumber,
                          let bounds = try numericBounds(bar, nativeScrollOwner: node) else {
                        if try scrollPages() { return result }
                        return try supportedFailure("scroll_range_unavailable", "The scroll control did not expose its numeric range.")
                    }
                    let low = bounds.0, high = bounds.1, start = before.doubleValue
                    guard start.isFinite, start >= low, start <= high else {
                        if try scrollPages() { return result }
                        return try supportedFailure("scroll_range_unavailable", "The scroll control has no usable numeric range.")
                    }
                    let sign = ["down", "right"].contains(action.direction) ? 1.0 : -1.0
                    let vertical = ["up", "down"].contains(action.direction)
                    let viewport = node.frame.map { vertical ? $0.height : $0.width } ?? 0
                    let content = node.children.filter { $0.role != "AXScrollBar" }.compactMap { $0.frame.map { vertical ? $0.height : $0.width } }.max() ?? 0
                    let thumb = bar.children.first(where: { $0.role == "AXValueIndicator" })?.frame.map { vertical ? $0.height : $0.width } ?? 0
                    let track = bar.frame.map { vertical ? $0.height : $0.width } ?? 0
                    let pageFraction = content > viewport && viewport > 0 ? viewport / (content - viewport)
                        : (thumb > 0 && track > thumb ? thumb / (track - thumb) : 0)
                    guard pageFraction > 0, pageFraction.isFinite else {
                        if try scrollPages() { return result }
                        return try supportedFailure("scroll_extent_unavailable", "The scroll control did not expose a page extent.")
                    }
                    let target = min(high, max(low, start + sign * (high - low) * pageFraction * ceil(Double(action.amount) / 3)))
                    result.behavior = "scroll"; result.element_id = node.id
                    guard target != start else { result.status = "no_effect"; result.effect = "scroll_boundary"; return result }
                    let accepted = try record(bar.id, kind: "attribute", name: "AXValue", outcome: .returned(access.write(bar.id, "AXValue", NSNumber(value: target))))
                    guard accepted else { return try supportedFailure("scroll_value_rejected", "The scroll control rejected the requested position.") }
                    result.state_check = NativeStateCheck(receiver_id: bar.id, property: "value",
                        comparison: sign > 0 ? "increase" : "decrease", before: start, matched_effect: "scroll_position_changed")
                    let after = (try access.read(bar.id, "AXValue") as? NSNumber)?.doubleValue
                    if let after, after.isFinite, (after - start) * sign > 0 {
                        result.effect = "scroll_position_changed"; return result
                    }
                    // Remote providers can accept the write before their AX cache
                    // reflects it. Confirm against the existing post-action capture,
                    // not this same-turn read. No second mutation or extra wait.
                    result.effect = "scroll_position_unconfirmed"
                    return result
                }
                if try scrollPages() { return result }
                return try supportedFailure("unsupported_native_action", "The target does not support background scrolling.")
            }
            guard action.kind == "click" else { return try supportedFailure("unsupported_action", "Unsupported spatial action.") }
            // Repeated or modified clicks have no Accessibility equivalent.
            if action.pointer || action.clickCount > 1 || !action.modifiers.isEmpty { return try pointerClick(chain[0]) }
            let selection = try NativeSelectionResolver.resolve(chain: chain, access: access)
            for node in chain {
                // Disabled genuine controls must not fall through to a parent.
                if Self.pressable.contains(node.role) || Self.editable.contains(node.role) || Self.adjustable.contains(node.role) || ["AXRow", "AXTab"].contains(node.role) {
                    try access.validateControl(node)
                }
                if Self.pressable.contains(node.role) {
                    if Self.menuOpeners.contains(node.role) { try requireActivation() }
                    if try perform(node, "AXPress", behavior: "press") { return result }
                }
                if let selection, selection.item.id == node.id {
                    if let owner = selection.membershipOwner, let attribute = selection.membershipAttribute {
                        try access.validateControl(owner)
                        guard let ownerIndex = chain.firstIndex(where: { $0.id == owner.id }),
                              let liveItem = try NativeSelectionResolver.member(owner: owner, attribute: attribute,
                                path: Array(chain.prefix(ownerIndex)), access: access), liveItem.id == selection.item.id else {
                            throw NativeInteractionFailure(code: "native_target_changed", message: "The item no longer belongs to the selection container. Observe again.")
                        }
                    }
                    let value: CFTypeRef = selection.attribute == "AXSelected" ? kCFBooleanTrue
                        : [try access.element(selection.item.id)] as CFArray
                    let previous = selection.attribute == "AXSelected" ? nil
                        : try access.read(selection.receiver.id, selection.attribute) as? [CFTypeRef]
                    guard try write(selection.receiver, selection.attribute, value,
                        target: selection.item, behavior: "select") else {
                        return try supportedFailure("selection_unavailable", "The validated selection operation is no longer writable.")
                    }
                    var applied: Bool
                    var unchanged = false
                    if selection.attribute == "AXSelected" {
                        applied = (try access.read(selection.item.id, "AXSelected") as? NSNumber)?.boolValue == true
                        unchanged = !applied
                    } else {
                        let target = try access.element(selection.item.id)
                        let selected = try access.read(selection.receiver.id, selection.attribute) as? [CFTypeRef] ?? []
                        applied = selected.count == 1 && selected.contains { CFEqual($0, target) }
                        // Apps that navigate on selection (Finder's sidebar) can rebuild
                        // the selected row before it is read back.
                        if !applied, selected.count == 1 { applied = try access.sameControl(selected[0], as: selection.item.id) }
                        unchanged = selected.count == (previous?.count ?? 0) &&
                            zip(selected, previous ?? []).allSatisfy { CFEqual($0.0, $0.1) }
                        if !applied && selected.count > 1 { unchanged = true }
                    }
                    if !applied && unchanged && selection.attribute != "AXSelected",
                       (try access.read(selection.receiver.id, selection.attribute) as? [CFTypeRef])?.count ?? 0 > 1 {
                        // Not the requested single item.
                        result.status = "failed"; result.code = "selection_not_applied"
                        result.error = "The selection did not match the requested item."
                        return result
                    }
                    if !applied {
                        // Accepted, but the immediate readback cannot show it yet (or the
                        // app ignored it). The fresh post-action capture decides; never repeat.
                        result.effect = "selection_unconfirmed"
                        result.selection_check = NativeSelectionCheck(receiver_id: selection.item.id)
                        return result
                    }
                    result.effect = "selection_set"; return result
                }
                if Self.adjustable.contains(node.role), try adjust(node, at: action.point) { return result }
                if selection == nil && (Self.editable.contains(node.role) || node.subrole == "AXSearchField") {
                    return try positionCaret(node)
                }
                // Custom controls may declare AXPress on a generic role. Only the
                // geometrically validated chain is inspected, never sibling controls.
                // In web content such a press is a simulated click at the element's
                // origin, not the requested point (canvas, click-handler regions),
                // so the window-bound pointer click keeps the position.
                if !Self.pressable.contains(node.role), try access.actionNames(node.id).contains("AXPress") {
                    if chain.contains(where: { $0.role == "AXWebArea" }) { return try pointerClick(node) }
                    if try perform(node, "AXPress", behavior: "press") { return result }
                }
            }
            // Web content handles clicks on arbitrary elements (canvas, custom
            // widgets) that expose no Accessibility operation. Only when nothing
            // was dispatched, so an uncertain operation is never repeated.
            if result.operations.isEmpty, chain.contains(where: { $0.role == "AXWebArea" }) {
                return try pointerClick(chain[0])
            }
            result.status = "no_effect"; result.behavior = "no_effect"; result.effect = "no_primary_interaction"
            result.supported = try chain.map { try access.capabilities($0.id) }
            return result
        } catch let failure as NativeInteractionFailure {
            result.status = "failed"; result.code = failure.code; result.error = failure.message
            result.effect = result.operations.isEmpty ? "not_attempted" : "change_possible"
            return result
        }
    }

    static func replacingSelection(_ current: String, range: CFRange, text: String) -> (text: String, cursor: Int)? {
        guard range.location >= 0, range.length >= 0,
              range.location <= current.utf16.count, range.length <= current.utf16.count - range.location,
              let start16 = current.utf16.index(current.utf16.startIndex, offsetBy: range.location, limitedBy: current.utf16.endIndex),
              let end16 = current.utf16.index(start16, offsetBy: range.length, limitedBy: current.utf16.endIndex),
              let start = String.Index(start16, within: current), let end = String.Index(end16, within: current) else { return nil }
        return (current.replacingCharacters(in: start..<end, with: text), range.location + text.utf16.count)
    }
}
