import ApplicationServices

struct NativeKeyboardMenu<Handle> {
    let windowID: CGWindowID
    let element: Handle
    let children: [Handle]
}

// Keyboard events address an app, not an AX control. Retain the control/window
// that authorized the command; never substitute whichever receiver is current.
struct NativeKeyboardReceiver<Handle> {
    let windowID: CGWindowID
    let focusedElement: Handle?
    var menu: Handle? = nil

    // A tracking menu may clear the app's focused window, or host its focused
    // search field in another native window. Only one menu in the allowed live
    // window trees, with focus on the app itself or that exact menu, can own keys.
    static func trackingMenu(_ menus: [NativeKeyboardMenu<Handle>], focused: Handle?,
        application: Handle, focusedWindow: Handle?, ancestry: (Handle) -> [Handle],
        equal: (Handle, Handle) -> Bool) -> Self? {
        guard menus.count == 1, let menu = menus.first else { return nil }
        if let focused, !equal(focused, application) {
            guard equal(focused, menu.element) || NativeRelatedUI.menuContains(
                ancestry: ancestry(focused), children: menu.children, equal: equal) else { return nil }
        } else if focusedWindow != nil { return nil }
        return Self(windowID: menu.windowID, focusedElement: focused, menu: menu.element)
    }

    func matches(_ current: Self?, equal: (Handle, Handle) -> Bool) -> Bool {
        guard let current, current.windowID == windowID else { return false }
        switch (menu, current.menu) {
        case (nil, nil): break
        case (let expected?, let actual?) where equal(expected, actual): break
        default: return false
        }
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
