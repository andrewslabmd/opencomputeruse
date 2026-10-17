import AppKit
import ApplicationServices
import Foundation

// Working in the frontmost app is allowed, and the user may bring any app forward
// at any time, including the one an agent is working in, to watch it. What is
// undone is narrower: an app taking the front as a reaction to OCU's own input.
// macOS only lets an app activate itself after real input delivered to it, so
// the guard watches only right after OCU posts keystrokes or pointer clicks (and
// app launches), never around Accessibility actions, activation or observation.
// Any sign of the user (a click, or Command/Control held, as in Cmd+Tab,
// Spotlight or Spaces), including just before OCU's input, means the user chose:
// the guard stands down and never touches the foreground. Only input timing and
// modifier state are read, never key content.
struct ForegroundGuardEvent: Encodable {
    let detected_ms: UInt64
    let previous_pid: pid_t
    let previous_name: String?
    let intruder_pid: pid_t
    let intruder_name: String?
    let target_pid: pid_t?
    let outcome: String // "restored", "restore_failed", "user_switch"
    let restore_ms: Int?
}

protocol ForegroundGuardAccess {
    func frontmost() -> pid_t?
    func name(_ pid: pid_t) -> String?
    /// Seconds since the last physical mouse-down (content is never read).
    func secondsSinceMouseDown() -> TimeInterval
    /// Whether Command or Control is physically held right now (app-switch keys).
    func switchModifierHeld() -> Bool
    func restore(_ pid: pid_t) -> Bool
    func now() -> Date
}

final class ForegroundGuard: @unchecked Sendable {
    /// Apps that react to OCU's input do so within a few hundred milliseconds (Finder ~330 ms).
    static let settleWindow: TimeInterval = 1.0
    /// A user click shortly before OCU's input still counts as the user's choice.
    static let userLookback: TimeInterval = 0.5
    /// The helper-wide instance used by the input dispatcher.
    nonisolated(unsafe) static var shared: ForegroundGuard?

    private let access: ForegroundGuardAccess
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OpenComputerUse.foreground-guard")
    private var timer: DispatchSourceTimer?
    private var previous: pid_t?
    private var target: pid_t?
    private var armedAt = Date.distantPast
    private var deadline: Date?
    private var active = 0
    private var userSeen = false
    private var events: [ForegroundGuardEvent] = []
    private let autoTick: Bool

    init(access: ForegroundGuardAccess, autoTick: Bool = true) { self.access = access; self.autoTick = autoTick }

    /// Called immediately before OCU posts input (or launches an app).
    func arm(target: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        if active == 0 && deadline.map({ access.now() > $0 }) != false {
            guard let front = access.frontmost() else { return }
            previous = front; armedAt = access.now(); userSeen = access.switchModifierHeld()
        }
        if previous == nil { return }
        self.target = target ?? self.target
        active += 1; deadline = nil
        startTimer()
    }

    /// Called when the input has been posted; the app may still react shortly afterwards.
    func settle() {
        lock.lock(); defer { lock.unlock() }
        guard active > 0 else { return }
        active -= 1
        if active == 0 { deadline = access.now().addingTimeInterval(Self.settleWindow) }
    }

    func events(since ms: UInt64) -> [ForegroundGuardEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.detected_ms >= ms }
    }

    private func startTimer() {
        guard autoTick, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source; source.resume()
    }

    private func standDown() { previous = nil; target = nil; deadline = nil; userSeen = false; timer?.cancel(); timer = nil }

    func tick() {
        lock.lock()
        guard let previous else { lock.unlock(); return }
        if active == 0, let deadline, access.now() > deadline { standDown(); lock.unlock(); return }
        // Sampled continuously: Cmd+Tab and similar hold the modifier while switching.
        if access.switchModifierHeld() { userSeen = true }
        guard let front = access.frontmost(), front != previous else { lock.unlock(); return }
        let target = self.target
        let userSwitch = userSeen || access.secondsSinceMouseDown() <= access.now().timeIntervalSince(armedAt) + Self.userLookback
        lock.unlock()

        var outcome = "user_switch", restoreMS: Int?
        if !userSwitch {
            let started = access.now()
            outcome = access.restore(previous) ? "restored" : "restore_failed"
            restoreMS = Int(access.now().timeIntervalSince(started) * 1000)
        }
        let event = ForegroundGuardEvent(detected_ms: UInt64(access.now().timeIntervalSince1970 * 1000),
            previous_pid: previous, previous_name: access.name(previous), intruder_pid: front,
            intruder_name: access.name(front), target_pid: target, outcome: outcome, restore_ms: restoreMS)
        lock.lock()
        events.append(event); if events.count > 64 { events.removeFirst(events.count - 64) }
        // One correction per OCU input at most; anything after that is left alone.
        standDown()
        lock.unlock()
    }
}

struct SystemForegroundGuardAccess: ForegroundGuardAccess {
    func frontmost() -> pid_t? { NativeAppTarget.frontmostPID() }
    func name(_ pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.localizedName }
    func secondsSinceMouseDown() -> TimeInterval {
        let since = { (type: CGEventType) in CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) }
        return min(since(.leftMouseDown), since(.rightMouseDown), since(.otherMouseDown))
    }
    func switchModifierHeld() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl]).isEmpty
    }
    func restore(_ pid: pid_t) -> Bool {
        // Accessibility's frontmost attribute is the assistive-technology route; the
        // public activation call is the fallback. Neither moves the cursor or sends input.
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1)
        if AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while Date() < deadline {
            if frontmost() == pid { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return frontmost() == pid
    }
    func now() -> Date { Date() }
}
