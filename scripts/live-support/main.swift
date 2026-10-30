import AppKit
import ApplicationServices
import IOKit

// Compiled by test-native-finder.mjs; never run by pnpm check. Passive only.
let helperPID = Int64(CommandLine.arguments[1])!
var activity = LiveTestActivity(helperPID: helperPID)
var baselineForeground: pid_t?
var baselinePointer: NSPoint?
func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject:value, options:[.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
func stop(_ reason: String) -> Never { emit(["state":"stopped","reason":reason]); exit(2) }
let types: [CGEventType] = [.keyDown,.keyUp,.flagsChanged,.mouseMoved,.leftMouseDown,.leftMouseUp,
    .rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel,.tabletPointer,.tabletProximity]
let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
guard let tap = CGEvent.tapCreate(tap:.cghidEventTap, place:.headInsertEventTap, options:.listenOnly,
    eventsOfInterest:mask, callback:{ _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { stop("input monitor disabled") }
        activity.event(sourcePID:event.getIntegerValueField(.eventSourceUnixProcessID),
            privateSource:event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.privateState.rawValue),
            tag:event.getIntegerValueField(.eventSourceUserData))
        if activity.stopped { stop("user or unrecognized input") }
        return Unmanaged.passUnretained(event)
    }, userInfo:nil) else { stop("passive input monitor unavailable; grant Input Monitoring to the terminal first") }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0),.commonModes)
func sample() {
    guard CGEvent.tapIsEnabled(tap:tap) else { stop("input monitor unavailable") }
    guard let session=CGSessionCopyCurrentDictionary() as? [String:Any],
          let console=session[kCGSessionOnConsoleKey as String] as? Bool else { stop("session state unavailable") }
    let unlocked=console && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
        && (session[kCGSessionLoginDoneKey as String] as? Bool == true)
    let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { stop("HID idle service unavailable") }
    defer { IOObjectRelease(service) }
    guard let raw=IORegistryEntryCreateCFProperty(service,"HIDIdleTime" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber else { stop("HID idle unavailable") }
    let idle=raw.doubleValue/1e9
    let front=NSWorkspace.shared.frontmostApplication
    let background=front != nil && front?.bundleIdentifier != "com.apple.finder" && front?.bundleIdentifier != "com.apple.loginwindow"
    if activity.qualified && (front?.processIdentifier != baselineForeground || NSEvent.mouseLocation != baselinePointer) {
        stop("foreground or physical pointer changed")
    }
    let wasReady=activity.qualified
    activity.sample(unlocked:unlocked,idle:idle,background:background)
    if activity.stopped { stop("screen locked or Finder became foreground") }
    if activity.qualified && !wasReady {
        baselineForeground=front?.processIdentifier; baselinePointer=NSEvent.mouseLocation
    }
    emit(["state":activity.qualified ? "ready":"waiting","idle":idle,"unlocked":unlocked,
        "foreground_pid":front?.processIdentifier ?? 0,"pointer":[NSEvent.mouseLocation.x,NSEvent.mouseLocation.y]])
}
let timer=Timer(timeInterval:0.1,repeats:true) { _ in sample() }
RunLoop.current.add(timer,forMode:.common)
sample()
RunLoop.current.run()
