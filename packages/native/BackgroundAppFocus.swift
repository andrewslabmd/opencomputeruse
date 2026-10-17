import AppKit
import ApplicationServices
import Foundation

protocol BackgroundAppFocusAccess {
    func identity(_ pid: pid_t) throws -> NativeProcessIdentity?
    func foregroundPID() -> pid_t?
    func logicalActive(_ pid: pid_t) throws -> Bool?
    func notify(_ pid: pid_t, active: Bool) throws
    func waitForState(_ pid: pid_t, active: Bool, cancelled: () -> Bool) throws
}

struct BackgroundAppFocusFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BackgroundAppFocusResult: Encodable {
    let token: String
    let mode: String
    var cleanup: String?
}

// State belongs to one owned workflow, not to the application's lifetime.
// Each agent (owner process) holds at most one lease, so agents working in
// different apps keep their own activation; two agents never share a target.
// Process-exit cleanup runs outside the helper's snapshot-collection thread.
final class BackgroundAppFocus: @unchecked Sendable {
    private final class NotificationCompletion: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        func wait() throws { done.wait(); if let error { throw error } }
    }
    private final class Lease {
        let token: String
        let target: NativeProcessIdentity
        let owner: pid_t
        let ownerIdentity: NativeProcessIdentity?
        var mode = "unchanged"
        var activationPosted = false
        var deactivationPosted = false
        var userActivated = false
        var ending = false
        var watch: DispatchSourceProcess?
        var guardObject: AppStateEventGuard?
        init(token: String, target: NativeProcessIdentity, owner: pid_t, ownerIdentity: NativeProcessIdentity?) {
            self.token = token; self.target = target; self.owner = owner; self.ownerIdentity = ownerIdentity
        }
    }
    private let access: BackgroundAppFocusAccess
    private let lock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "OpenComputerUse.background-focus-cleanup")
    private let notificationQueue = DispatchQueue(label: "OpenComputerUse.background-focus-notifications")
    private let cleanupKey = DispatchSpecificKey<UInt8>()
    private var leases: [pid_t: Lease] = [:] // by owner
    private var foregroundMonitor: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?

    init(access: BackgroundAppFocusAccess) {
        self.access = access
        cleanupQueue.setSpecific(key: cleanupKey, value: 1)
    }

    func monitorUserActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            self?.userActivated(pid)
        }
        let timer = DispatchSource.makeTimerSource(queue: cleanupQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            guard let self, let pid = self.access.foregroundPID() else { return }
            self.userActivated(pid)
        }
        foregroundMonitor = timer; timer.resume()
    }

    func userActivated(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        for entry in leases.values where entry.target.pid == pid { entry.userActivated = true }
    }

    var hasLeases: Bool { lock.lock(); defer { lock.unlock() }; return !leases.isEmpty }

    func suppressDeactivation(pid: pid_t, sourcePID: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = leases.values.first(where: { $0.target.pid == pid }) else { return false }
        let foreground = access.foregroundPID() == entry.target.pid
        if foreground { entry.userActivated = true }
        guard entry.activationPosted else { return false }
        if sourcePID == getpid() { return foreground || entry.userActivated }
        return sourcePID == 0 && !entry.ending && !foreground && !entry.userActivated
    }

    private func enqueueNotification(_ entry: Lease, active: Bool) -> NotificationCompletion {
        let completion = NotificationCompletion()
        notificationQueue.async { [self] in
            // Never hold the lease lock across event delivery: the target's
            // event tap can call back into this manager while delivery runs.
            do {
                let foreground = access.foregroundPID() == entry.target.pid
                let currentIdentity = try access.identity(entry.target.pid)
                lock.lock()
                if foreground { entry.userActivated = true }
                let allowed = leases[entry.owner] === entry && currentIdentity == entry.target &&
                    !entry.userActivated && !foreground && (!active || !entry.ending)
                if active && !allowed && entry.userActivated { entry.mode = "user_active" }
                // Record a possible dispatch only after identity preparation
                // succeeds. A failed lookup has not sent an uncertain event.
                if allowed {
                    if active { entry.activationPosted = true }
                    else { entry.deactivationPosted = true }
                }
                lock.unlock()
                if allowed { try access.notify(entry.target.pid, active: active) }
            }
            catch { completion.error = error }
            completion.done.signal()
        }
        return completion
    }

    func begin(pid: pid_t, owner: pid_t, watchOwner: Bool = true, guardEvents: Bool = true) throws -> BackgroundAppFocusResult {
        guard owner > 0 else { throw BackgroundAppFocusFailure(message: "Invalid action owner process ID.") }
        let ownerIdentity = watchOwner ? try NativeProcessIdentity.read(owner) : nil
        guard !watchOwner || ownerIdentity != nil else {
            throw BackgroundAppFocusFailure(message: "The action owner process exited.")
        }
        guard let identity = try access.identity(pid) else {
            throw BackgroundAppFocusFailure(message: "The target process exited.")
        }
        lock.lock()
        let previous = leases[owner]
        let previousAvailable = previous.map { $0.ownerIdentity == ownerIdentity && !$0.ending && !$0.deactivationPosted } ?? true
        let previousReusable = previous.map { $0.target == identity && !$0.userActivated } ?? false
        let heldByAnother = leases.values.contains { $0.owner != owner && $0.target.pid == pid }
        lock.unlock()
        guard !heldByAnother else {
            throw BackgroundAppFocusFailure(message: "Another agent holds this app's background focus.")
        }
        if let previous {
            guard previousAvailable else {
                throw BackgroundAppFocusFailure(message: "Background app focus belongs to another owner or is being restored.")
            }
            if previousReusable && access.foregroundPID() != pid {
                let previousActive = try access.logicalActive(pid)
                if previous.activationPosted && previousActive != true {
                    _ = try end(token: previous.token, owner: owner)
                    throw BackgroundAppFocusFailure(message: "The target lost its owned background activation. Observe again.")
                }
                lock.lock(); defer { lock.unlock() }
                guard leases[owner] === previous, !previous.ending, !previous.deactivationPosted else {
                    throw BackgroundAppFocusFailure(message: "The background app workflow was cancelled.")
                }
                return BackgroundAppFocusResult(token: previous.token, mode: previous.mode)
            }
            _ = try end(token: previous.token, owner: owner)
        }
        let entry = Lease(token: UUID().uuidString, target: identity, owner: owner, ownerIdentity: ownerIdentity)
        lock.lock()
        guard leases[owner] == nil else { lock.unlock(); throw BackgroundAppFocusFailure(message: "Background app focus cleanup is still in progress.") }
        guard !leases.values.contains(where: { $0.target.pid == pid }) else {
            lock.unlock(); throw BackgroundAppFocusFailure(message: "Another agent holds this app's background focus.")
        }
        leases[owner] = entry
        lock.unlock()
        if watchOwner {
            let source = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: cleanupQueue)
            source.setEventHandler { [weak self] in _ = try? self?.end(token: entry.token) }
            lock.lock(); entry.watch = source; lock.unlock(); source.resume()
        }
        do {
            let active = try access.logicalActive(pid)
            var notification: NotificationCompletion?
            if active == false && access.foregroundPID() != pid && guardEvents {
                let eventGuard = AppStateEventGuard(pid: pid,
                    realActivation: { [weak self] in self?.userActivated(pid) },
                    suppress: { [weak self] in self?.suppressDeactivation(pid: pid, sourcePID: $0) ?? false })
                try eventGuard.start()
                lock.lock()
                guard leases[owner] === entry, !entry.ending else {
                    lock.unlock(); eventGuard.stop(); throw BackgroundAppFocusFailure(message: "Background app focus was cancelled.")
                }
                entry.guardObject = eventGuard
                lock.unlock()
            }
            let currentTarget = try access.identity(pid)
            let currentOwner = watchOwner ? try NativeProcessIdentity.read(owner) : nil
            lock.lock()
            guard leases[owner] === entry, !entry.ending, currentOwner == ownerIdentity, currentTarget == identity else {
                lock.unlock(); throw BackgroundAppFocusFailure(message: "Background app focus was cancelled before activation.")
            }
            if access.foregroundPID() == pid || entry.userActivated {
                entry.mode = "user_active"
            } else if active == true {
                entry.mode = "already_active"
            } else if active == nil {
                // Providers without an app-level state retain their existing AX
                // behavior. Do not invent an activation requirement for them.
                entry.mode = "state_unavailable"
            } else {
                entry.mode = "synthetic"
                notification = enqueueNotification(entry, active: true)
            }
            lock.unlock()
            try notification?.wait()
            lock.lock(); let posted = entry.activationPosted; lock.unlock()
            if posted {
                try access.waitForState(pid, active: true) { [weak self] in
                    guard let self else { return true }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.leases[owner] !== entry || entry.ending
                }
            }
            let acknowledgedTarget = try access.identity(pid)
            lock.lock(); defer { lock.unlock() }
            guard leases[owner] === entry, !entry.ending, acknowledgedTarget == identity else { throw BackgroundAppFocusFailure(message: "Background app focus was cancelled or its process changed.") }
            return BackgroundAppFocusResult(token: entry.token, mode: entry.mode)
        } catch {
            _ = try? end(token: entry.token)
            throw error
        }
    }

    func end(token: String, owner: pid_t? = nil) throws -> BackgroundAppFocusResult {
        lock.lock(); let held = leases.values.first { $0.token == token }
        let permitted = held == nil || owner == nil || held?.owner == owner; lock.unlock()
        guard permitted else { throw BackgroundAppFocusFailure(message: "The native action focus belongs to another owner.") }
        if DispatchQueue.getSpecific(key: cleanupKey) != nil { return try finish(token: token) }
        return try cleanupQueue.sync { try finish(token: token) }
    }

    private func finish(token: String) throws -> BackgroundAppFocusResult {
        lock.lock()
        guard let entry = leases.values.first(where: { $0.token == token }) else {
            lock.unlock(); return BackgroundAppFocusResult(token: token, mode: "unchanged", cleanup: "already_released")
        }
        guard !entry.ending else {
            lock.unlock(); throw BackgroundAppFocusFailure(message: "Background app focus cleanup is already running.")
        }
        entry.ending = true
        lock.unlock()
        do {
            let sameProcess = try access.identity(entry.target.pid) == entry.target
            lock.lock()
            let userOwns = entry.userActivated || access.foregroundPID() == entry.target.pid
            var cleanup = sameProcess ? "preserved" : "process_exited"
            let restore = sameProcess && entry.activationPosted && !userOwns
            var notification: NotificationCompletion?
            if userOwns { cleanup = "user_active" }
            if restore && !entry.deactivationPosted {
                notification = enqueueNotification(entry, active: false)
            }
            lock.unlock()
            try notification?.wait()
            if restore {
                var identityError: Error?
                try access.waitForState(entry.target.pid, active: false) { [weak self] in
                    guard let self else { return true }
                    let current: NativeProcessIdentity?
                    do { current = try self.access.identity(entry.target.pid) }
                    catch { identityError = error; return true }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return current != entry.target || entry.userActivated || self.access.foregroundPID() == entry.target.pid
                }
                if let identityError { throw identityError }
                cleanup = "restored"
            }
            let finalIdentity = try access.identity(entry.target.pid)
            lock.lock()
            if finalIdentity != entry.target { cleanup = "process_exited" }
            else if entry.userActivated || access.foregroundPID() == entry.target.pid { cleanup = "user_active" }
            if leases[entry.owner] === entry { leases[entry.owner] = nil }
            entry.watch?.cancel(); entry.watch = nil
            let eventGuard = entry.guardObject; entry.guardObject = nil
            lock.unlock()
            eventGuard?.stop()
            return BackgroundAppFocusResult(token: token, mode: entry.mode, cleanup: cleanup)
        } catch {
            // Dispatch is not repeated after an uncertain native response. A
            // later owner-release/exit check can confirm the restored state.
            lock.lock(); entry.ending = false; lock.unlock()
            throw error
        }
    }

    /// One owner's lease, or every lease (helper shutdown) when owner is nil.
    func release(owner: pid_t? = nil) throws -> BackgroundAppFocusResult? {
        lock.lock()
        let tokens = owner.map { leases[$0].map { [$0.token] } ?? [] } ?? leases.values.map(\.token)
        lock.unlock()
        var last: BackgroundAppFocusResult?
        for token in tokens { last = try end(token: token) }
        return last
    }

    func releaseIfTargetChanged(identity: NativeProcessIdentity, owner: pid_t) throws {
        lock.lock()
        let token = leases[owner].flatMap { $0.target != identity ? $0.token : nil }
        lock.unlock()
        if let token { _ = try end(token: token, owner: owner) }
    }

    deinit {
        foregroundMonitor?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

struct AXBackgroundAppFocusAccess: BackgroundAppFocusAccess {
    func identity(_ pid: pid_t) throws -> NativeProcessIdentity? { try NativeProcessIdentity.read(pid) }
    func foregroundPID() -> pid_t? { NativeAppTarget.frontmostPID() }
    func logicalActive(_ pid: pid_t) throws -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXFrontmost" as CFString, &value)
        if [.attributeUnsupported, .notImplemented, .noValue].contains(error) { return nil }
        guard error == .success else { throw BackgroundAppFocusFailure(message: "Reading background app state failed (AXError \(error.rawValue)).") }
        return (value as? NSNumber)?.boolValue
    }
    func notify(_ pid: pid_t, active: Bool) throws {
        guard CGPreflightPostEventAccess(), let event = NSEvent.otherEvent(
            with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: active ? 1 : 2, data1: 0, data2: 0
        )?.cgEvent else { throw BackgroundAppFocusFailure(message: "Background application-state events are unavailable.") }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.postToPid(pid)
    }
    func waitForState(_ pid: pid_t, active: Bool, cancelled: () -> Bool) throws {
        // This is native event readiness within the existing two-second AX
        // operation bound, never a task-duration limit or an action retry.
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            if cancelled() { return }
            if try logicalActive(pid) == active { return }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        throw BackgroundAppFocusFailure(message: "The application did not acknowledge its background focus state.")
    }
}
