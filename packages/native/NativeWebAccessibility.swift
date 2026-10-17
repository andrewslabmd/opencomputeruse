import ApplicationServices
import Foundation

// Electron keeps Chromium in a reduced accessibility mode in which web nodes
// advertise AXPress, accept it, and never deliver it to the page. Electron's
// application-level AXManualAccessibility switch requests complete mode, which
// Electron applies after its own two-second debounce. Its getter compares for
// exact mode equality and stays false after the switch, so it cannot confirm
// readiness; the provider's debounce is the only contract available. Only a
// target advertising the switch as settable is changed: no app names, no
// AXEnhancedUserInterface side effects on native AppKit apps. The switch is
// not reverted: Electron keeps one shared mode, so a disable could remove a
// mode another assistive client requested and the getter cannot tell them apart.
protocol WebAccessibilityAccess {
    func switchSettable(_ pid: pid_t) throws -> Bool
    func requestComplete(_ pid: pid_t) throws
}

struct WebAccessibilityFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WebAccessibilityMode {
    static let attribute = "AXManualAccessibility"
    static let readiness: TimeInterval = 2.25 // Electron's 2s debounce plus delivery margin.
    private let access: WebAccessibilityAccess
    private let now: () -> Date
    private var requests: [(identity: NativeProcessIdentity, at: Date)] = []

    init(access: WebAccessibilityAccess, now: @escaping () -> Date = Date.init) {
        self.access = access; self.now = now
    }

    /// Requests complete mode once per kernel process identity. Returns the
    /// readiness time still remaining, or nil when the target has no switch.
    func prepare(_ identity: NativeProcessIdentity) throws -> TimeInterval? {
        if let request = requests.first(where: { $0.identity == identity }) {
            return max(0, Self.readiness - now().timeIntervalSince(request.at))
        }
        guard try access.switchSettable(identity.pid) else { return nil }
        try access.requestComplete(identity.pid)
        // A replaced PID is a different process; it gets its own request.
        requests.removeAll { $0.identity.pid == identity.pid }
        requests.append((identity, now()))
        return Self.readiness
    }
}

struct AXWebAccessibilityAccess: WebAccessibilityAccess {
    func switchSettable(_ pid: pid_t) throws -> Bool {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(app, WebAccessibilityMode.attribute as CFString, &settable)
        if [.attributeUnsupported, .notImplemented, .noValue].contains(error) { return false }
        guard error == .success else {
            throw WebAccessibilityFailure(message: "Reading the web accessibility switch failed (AXError \(error.rawValue)).")
        }
        return settable.boolValue
    }

    func requestComplete(_ pid: pid_t) throws {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        let error = AXUIElementSetAttributeValue(app, WebAccessibilityMode.attribute as CFString, kCFBooleanTrue)
        guard error == .success else {
            throw WebAccessibilityFailure(message: "Requesting complete web accessibility failed (AXError \(error.rawValue)).")
        }
    }
}
