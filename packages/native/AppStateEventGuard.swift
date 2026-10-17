import AppKit
import ApplicationServices

// Intercepts application-state notifications in the target process only.
// Physical mouse/keyboard events and Window Server's foreground state are
// never intercepted or changed.
final class AppStateEventGuard: @unchecked Sendable {
    private let pid: pid_t
    private let suppress: (pid_t) -> Bool
    private let realActivation: () -> Void
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopped = false

    init(pid: pid_t, realActivation: @escaping () -> Void, suppress: @escaping (pid_t) -> Bool) {
        self.pid = pid; self.suppress = suppress; self.realActivation = realActivation
    }
    func start() throws {
        let thread = Thread { [self] in
            let callback: CGEventTapCallBack = { _, kind, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let guardObject = Unmanaged<AppStateEventGuard>.fromOpaque(context).takeUnretainedValue()
                if kind == .tapDisabledByTimeout || kind == .tapDisabledByUserInput {
                    guardObject.lock.lock()
                    if let port = guardObject.port, !guardObject.stopped { CGEvent.tapEnable(tap: port, enable: true) }
                    guardObject.lock.unlock()
                } else if kind.rawValue == 13, let native = NSEvent(cgEvent: event) {
                    let source = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
                    if native.subtype.rawValue == 1 && source == 0 { guardObject.realActivation() }
                    if native.subtype.rawValue == 2 && guardObject.suppress(source) { return nil }
                }
                return Unmanaged.passUnretained(event)
            }
            let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: 1 << 13, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            lock.lock(); port = tap; loop = CFRunLoopGetCurrent(); let cancelled = stopped; lock.unlock()
            if let tap, !cancelled {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
                ready.signal(); CFRunLoopRun(); CFMachPortInvalidate(tap)
            } else { ready.signal(); if let tap { CFMachPortInvalidate(tap) } }
        }
        thread.name = "OpenComputerUse app-state guard"; thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            stop(); throw BackgroundAppFocusFailure(message: "The background application-state guard did not start.")
        }
        lock.lock(); let installed = port != nil && !stopped; lock.unlock()
        guard installed else { stop(); throw BackgroundAppFocusFailure(message: "The target application-state guard is unavailable.") }
    }
    func stop() {
        lock.lock(); stopped = true; let port = port; let loop = loop; lock.unlock()
        if let port { CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }
}
