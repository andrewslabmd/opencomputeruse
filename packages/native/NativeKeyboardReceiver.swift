import ApplicationServices

// Keyboard events address an app, not an AX control. Retain the control/window
// that authorized the command; never substitute whichever receiver is current.
struct NativeKeyboardReceiver<Handle> {
    let windowID: CGWindowID
    let focusedElement: Handle?

    func matches(_ current: Self?, equal: (Handle, Handle) -> Bool) -> Bool {
        guard let current, current.windowID == windowID else { return false }
        switch (focusedElement, current.focusedElement) {
        case (nil, nil): return true
        case (let expected?, let actual?): return equal(expected, actual)
        default: return false
        }
    }

    func validate(_ current: Self?, equal: (Handle, Handle) -> Bool) throws {
        guard matches(current, equal: equal) else {
            throw NativeInteractionFailure(code: "keyboard_target_changed",
                message: "The retained keyboard window or control changed. No key-down was sent.")
        }
    }
}
