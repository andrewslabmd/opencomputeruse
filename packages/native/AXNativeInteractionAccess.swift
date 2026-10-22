import ApplicationServices
import Foundation
import AppKit

final class NativeActionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AXError?
    func store(_ error: AXError) { lock.lock(); value = error; lock.unlock() }
    func load() -> AXError? { lock.lock(); defer { lock.unlock() }; return value }
}

// A pending action on an exact handle cannot be dispatched twice by a retry.
// Other handles remain usable so a menu item or Escape can finish menu tracking.
final class NativeActionRegistry: @unchecked Sendable {
    static let shared = NativeActionRegistry()
    private let lock = NSLock()
    private var pending: [(element: AXUIElement, action: String, completion: NativeActionCompletion)] = []
    func begin(_ element: AXUIElement, action: String) -> (completion: NativeActionCompletion, isNew: Bool) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0.completion.load() != nil }
        if let existing = pending.first(where: { CFEqual($0.element, element) && $0.action == action }) {
            return (existing.completion, false)
        }
        let completion = NativeActionCompletion()
        pending.append((element, action, completion))
        return (completion, true)
    }
}

final class NativeMutationReceivers {
    var ids = Set<String>()
}

struct AXNativeInteractionAccess: NativeInteractionAccess {
    let elements: [String: AXUIElement]
    let validateNode: (NativeInteractionNode, NativeInteractionNode?, NativeValidationPhase) throws -> Void
    let refreshNode: (NativeInteractionNode) throws -> NativeInteractionNode
    let checkInput: () throws -> Void
    let inputWindowID: CGWindowID
    var inputWindowFrame: CGRect = .null
    let mutationReceivers = NativeMutationReceivers()

    func validate(_ node: NativeInteractionNode) throws { try validateNode(node, nil, mutationReceivers.ids.contains(node.id) ? .receiver : .point) }
    func validateRelated(_ node: NativeInteractionNode, owner: NativeInteractionNode) throws { try validateNode(node, owner, .point) }
    func refreshAfterMutation(_ node: NativeInteractionNode) throws -> NativeInteractionNode {
        try validateNode(node, nil, .identity)
        let updated = try refreshNode(node)
        mutationReceivers.ids.insert(node.id)
        return updated
    }
    func handle(_ id: String) throws -> AXUIElement {
        guard let e = elements[id] else { throw NativeInteractionFailure(code: "native_target_changed", message: "The native target expired. Observe again.") }
        return e
    }
    func read(_ id: String, _ attribute: String) throws -> CFTypeRef? {
        let e = try handle(id)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
        if [.attributeUnsupported, .noValue, .notImplemented].contains(error) { return nil }
        guard error == .success else { throw NativeInteractionFailure(code: "native_attribute_failed", message: "Reading \(attribute) failed (AXError \(error.rawValue)). Observe again.") }
        return value
    }
    func write(_ id: String, _ attribute: String, _ value: CFTypeRef) throws -> AXError {
        let element = try handle(id)
        // Focus moves inside the retained target app are allowed, foreground or
        // not: they never activate an app or bring one to the front.
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
    func ownsKeyboardFocus(_ id: String) throws -> Bool {
        let element = try handle(id)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The focus target process changed.")
        }
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role)
        guard roleError == .success else {
            throw NativeInteractionFailure(code: "native_attribute_failed", message: "Reading the focus target role failed (AXError \(roleError.rawValue)).")
        }
        let attribute = (role as? String) == "AXWindow" ? "AXFocusedWindow" : "AXFocusedUIElement"
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), attribute as CFString, &focused)
        if error == .noValue { return false }
        guard error == .success else {
            throw NativeInteractionFailure(code: "native_attribute_failed", message: "Reading \(attribute) failed (AXError \(error.rawValue)).")
        }
        return focused.map { CFEqual($0, element) } ?? false
    }
    func inputText(_ id: String, _ text: String) throws -> String {
        let element=try handle(id);var pid:pid_t=0
        guard AXUIElementGetPid(element,&pid) == .success,try ownsKeyboardFocus(id) else {
            throw NativeInteractionFailure(code:"keyboard_target_unavailable",message:"The retained editor no longer owns app keyboard focus. No text was sent.")
        }
        return try NativeKeyboardInput.shared.send(.literal(text),pid:pid,window:inputWindowID,receiver:id){
            try self.checkInput()
            guard try self.ownsKeyboardFocus(id) else{
                throw NativeInteractionFailure(code:"keyboard_target_unavailable",message:"The retained editor no longer owns app keyboard focus. No text was sent.")
            }
        }
    }
    func pointerGesture(_ id: String, _ gesture: NativePointerGesture) throws -> String {
        let element = try handle(id); var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The pointer target process changed. No pointer input was sent.")
        }
        // The receiver drops window-bound mouse events unless it is logically
        // active. Only the workflow's owned lease (or the user) may make it so;
        // this path never activates the app or changes the foreground.
        func requireActive() throws {
            guard try Self.active(pid) else {
                throw NativeInteractionFailure(code: "app_activation_required", message: "This operation needs the app's background activation. No pointer input was sent.")
            }
        }
        try requireActive()
        let plan = try NativeInputPlan.pointer(gesture, window: inputWindowID, frame: inputWindowFrame,
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        return try NativeKeyboardInput.shared.send(plan, pid: pid, window: inputWindowID, receiver: id) {
            try self.checkInput()
            try requireActive()
        }
    }
    func dragSessionMarker() -> Int { NSPasteboard(name: .drag).changeCount }
    func dragSessionStarted(since marker: Int) -> Bool {
        // The source writes the drag pasteboard as it begins the session, while
        // it handles the posted moves; allow it a moment to handle the last ones.
        let until = Date(timeIntervalSinceNow: 0.15)
        while true {
            if NSPasteboard(name: .drag).changeCount != marker { return true }
            if Date() >= until { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    func keyboardFocusWithin(_ ids: [String]) throws -> Bool {
        guard let first = ids.first else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(try handle(first), &pid) == .success else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The keyboard target process changed.")
        }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &focused)
        if error == .noValue { return true }
        guard error == .success else {
            throw NativeInteractionFailure(code: "native_attribute_failed", message: "Reading AXFocusedUIElement failed (AXError \(error.rawValue)).")
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return true }
        return try ids.contains { CFEqual(try handle($0), focused) }
    }
    func keyboardText(_ id: String, _ text: String, within ids: [String]) throws -> String {
        let element = try handle(id); var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The keyboard target process changed. No text was sent.")
        }
        func requireFocus() throws {
            guard try keyboardFocusWithin(ids) else {
                throw NativeInteractionFailure(code: "keyboard_target_unavailable", message: "The app's keyboard focus moved to another control. No further text was sent.")
            }
        }
        try requireFocus()
        return try NativeKeyboardInput.shared.send(.keystrokes(text), pid: pid, window: inputWindowID, receiver: id) {
            try self.checkInput()
            try requireFocus()
        }
    }
    func appActive() throws -> Bool {
        guard let any = elements.values.first else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(any, &pid) == .success else {
            throw NativeInteractionFailure(code: "native_target_changed", message: "The target process changed.")
        }
        return try Self.active(pid)
    }
    static func active(_ pid: pid_t) throws -> Bool {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXFrontmost" as CFString, &value)
        if [.attributeUnsupported, .notImplemented, .noValue].contains(error) { return false }
        guard error == .success else {
            throw NativeInteractionFailure(code: "native_attribute_failed", message: "Reading the app's activation state failed (AXError \(error.rawValue)).")
        }
        return (value as? NSNumber)?.boolValue == true
    }
    func parameterized(_ id: String, _ attribute: String, _ parameter: CFTypeRef) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(try handle(id), attribute as CFString, parameter, &value)
        if [.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue].contains(error) { return nil }
        guard error == .success else { throw NativeInteractionFailure(code: "native_attribute_failed", message: "\(attribute) returned AXError \(error.rawValue).") }
        return value
    }
    func scrollBar(_ owner: NativeInteractionNode, vertical: Bool) throws -> NativeInteractionNode? {
        guard let raw = try read(owner.id, vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let linked = unsafeBitCast(raw, to: AXUIElement.self)
        func find(_ node: NativeInteractionNode) -> NativeInteractionNode? {
            if node.role == "AXScrollBar", let handle = elements[node.id], CFEqual(handle, linked) { return node }
            for child in node.children { if let result = find(child) { return result } }
            return nil
        }
        return find(owner)
    }
    func element(_ id: String) throws -> CFTypeRef { try handle(id) }
    func sameControl(_ element: CFTypeRef, as id: String) throws -> Bool {
        let retained = try handle(id)
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let live = unsafeBitCast(element, to: AXUIElement.self)
        if CFEqual(live, retained) { return true }
        func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func text(_ e: AXUIElement, depth: Int = 0) -> [String] {
            var out = ["AXTitle", "AXDescription", "AXValue"].compactMap { value(e, $0) as? String }.filter { !$0.isEmpty }
            if depth < 3, let children = value(e, "AXChildren") as? [AXUIElement] {
                for child in children { out += text(child, depth: depth + 1) }
            }
            return out
        }
        func geometry(_ e: AXUIElement) -> CGRect? {
            guard let p = value(e, "AXPosition"), let z = value(e, "AXSize") else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(z as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        var livePID: pid_t = 0, retainedPID: pid_t = 0
        guard AXUIElementGetPid(live, &livePID) == .success, AXUIElementGetPid(retained, &retainedPID) == .success,
              livePID == retainedPID, (value(live, "AXRole") as? String) == (value(retained, "AXRole") as? String),
              let liveFrame = geometry(live), let retainedFrame = geometry(retained) else { return false }
        let liveText = text(live)
        return abs(liveFrame.minX - retainedFrame.minX) <= 1 && abs(liveFrame.minY - retainedFrame.minY) <= 1 &&
            abs(liveFrame.width - retainedFrame.width) <= 1 && abs(liveFrame.height - retainedFrame.height) <= 1 &&
            !liveText.isEmpty && liveText == text(retained)
    }
    func perform(_ id: String, _ action: String) throws -> NativeCallOutcome {
        let e = try handle(id)
        // Menu tracking can keep a successful AX action call open until the menu
        // closes. Report pending, not completed, and stop this batch. The exact
        // retained element is held by the task; no second hit-test occurs.
        let entry = NativeActionRegistry.shared.begin(e, action: action)
        guard entry.isNew else { return .pending }
        let completion = entry.completion
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            completion.store(AXUIElementPerformAction(e, action as CFString))
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .milliseconds(200)) == .success, let error = completion.load() {
            return .returned(error)
        }
        return .pending
    }
    func actionNames(_ id: String) throws -> [String] {
        let e = try handle(id)
        var raw: CFArray?
        let error = AXUIElementCopyActionNames(e, &raw)
        guard [.success, .actionUnsupported, .attributeUnsupported, .noValue, .notImplemented].contains(error) else {
            throw NativeInteractionFailure(code: "native_capabilities_failed", message: "Reading supported actions failed (AXError \(error.rawValue)).")
        }
        return (raw as? [String] ?? []).sorted()
    }
    func canWrite(_ id: String, _ name: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(try handle(id), name as CFString, &settable)
        guard [.success, .attributeUnsupported, .noValue, .notImplemented].contains(error) else {
            throw NativeInteractionFailure(code: "native_capabilities_failed", message: "Reading supported \(name) failed (AXError \(error.rawValue)).")
        }
        return error == .success && settable.boolValue
    }
    func capabilities(_ id: String) throws -> NativeSupportedOperations {
        let actions = try actionNames(id)
        var writable: [String] = []
        for name in ["AXFocused", "AXSelected", "AXSelectedRows", "AXSelectedChildren", "AXValue", "AXSelectedText", "AXSelectedTextRange"] {
            if try canWrite(id, name) { writable.append(name) }
        }
        return NativeSupportedOperations(id: id, actions: actions, writableAttributes: writable)
    }
}
