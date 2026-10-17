import AppKit
import ApplicationServices
import Foundation

struct NativeInputPlan {
    let source: CGEventSource
    let events: [CGEvent]
    let kind: String
    let textUnits: Int?
    /// Seconds to wait before posting each event (gestures, keystroke pacing).
    /// Empty: post back to back with creation timestamps.
    var delays: [TimeInterval] = []

    static let downTypes: Set<CGEventType> = [.keyDown, .leftMouseDown, .rightMouseDown]
    static let upTypes: Set<CGEventType> = [.keyUp, .leftMouseUp, .rightMouseUp]
    static let observedTypes: Set<CGEventType> = downTypes.union(upTypes).union([.leftMouseDragged, .flagsChanged])

    /// Whether an event presses a key, button or modifier that a later event releases.
    static func presses(_ event: CGEvent) -> Bool {
        downTypes.contains(event.type) || (event.type == .flagsChanged && !event.flags.isDisjoint(with: modifierMask))
    }
    static let modifierMask: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
    /// For each press, the index of the event that releases it.
    var releases: [Int: Int] {
        var result: [Int: Int] = [:]
        for (i, event) in events.enumerated() where Self.presses(event) {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            result[i] = events.indices.dropFirst(i + 1).first { j in
                let other = events[j]
                switch event.type {
                case .keyDown: return other.type == .keyUp && other.getIntegerValueField(.keyboardEventKeycode) == code
                case .flagsChanged: return other.type == .flagsChanged && other.getIntegerValueField(.keyboardEventKeycode) == code
                case .leftMouseDown: return other.type == .leftMouseUp
                case .rightMouseDown: return other.type == .rightMouseUp
                default: return false
                }
            }
        }
        return result
    }

    func bind(pid:pid_t,tag:Int64){for event in events{event.setIntegerValueField(.eventSourceUserData,value:tag);event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))}}

    static func literal(_ text: String) throws -> NativeInputPlan {
        let code: CGKeyCode = text.isEmpty ? 51 : 0
        let (source, pair) = try stroke(code: code, flags: [])
        if !text.isEmpty {
            let units = Array(text.utf16)
            pair[0].keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        return .init(source: source, events: pair, kind: "text", textUnits: text.utf16.count)
    }

    static func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "cmd", "command", "super": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "shift": return .maskShift
        case "alt", "option": return .maskAlternate
        case "fn": return .maskSecondaryFn
        default: return nil
        }
    }

    static func modifierFlags(_ names: [String]) throws -> CGEventFlags {
        try names.reduce(into: CGEventFlags()) { flags, name in
            guard let flag = modifierFlag(name) else {
                throw NativeInteractionFailure(code: "invalid_modifier", message: "Unknown modifier \(name). Nothing was sent.")
            }
            flags.insert(flag)
        }
    }

    static func shortcut(_ keys: [String]) throws -> NativeInputPlan {
        var flags: CGEventFlags = []
        var primary: String?
        for key in keys.map({ $0.lowercased() }) {
            if let flag = modifierFlag(key) { flags.insert(flag); continue }
            guard primary == nil else { throw NativeInteractionFailure(code: "invalid_hotkey", message: "A shortcut needs one primary key.") }
            primary = key
        }
        guard let primary, let code = codes[primary] else {
            throw NativeInteractionFailure(code: "invalid_hotkey", message: "The shortcut key is unsupported.")
        }
        let (source, events) = try stroke(code: code, flags: flags)
        return .init(source: source, events: events, kind: "hotkey", textUnits: nil)
    }

    /// Text as physical keystrokes, for surfaces that read key codes rather than
    /// the text payload (remote screens, device mirrors, games, canvases). Each
    /// character is one key press at its US-ANSI position with its text attached;
    /// Shift is pressed and released through this private source only. Characters
    /// without a key position are refused before anything is sent.
    static func keystrokes(_ text: String, pace: TimeInterval = 0.012) throws -> NativeInputPlan {
        guard !text.isEmpty else { throw NativeInteractionFailure(code: "invalid_text", message: "Keyboard text is empty. Nothing was sent.") }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw NativeInteractionFailure(code: "keyboard_input_unavailable", message: "Native keyboard events could not be created.")
        }
        var events: [CGEvent] = [], delays: [TimeInterval] = []
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, text: String?) throws {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw NativeInteractionFailure(code: "keyboard_input_unavailable", message: "Native keyboard events could not be created.")
            }
            event.flags = flags
            if let text { let units = Array(text.utf16); event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            else { event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil) }
            events.append(event); delays.append(events.count == 1 ? 0 : pace)
        }
        func shift(_ down: Bool) throws {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: down) else {
                throw NativeInteractionFailure(code: "keyboard_input_unavailable", message: "Native keyboard events could not be created.")
            }
            event.type = .flagsChanged; event.flags = down ? .maskShift : []
            events.append(event); delays.append(events.count == 1 ? 0 : pace)
        }
        let strokes = try text.map { character -> (CGKeyCode, Bool, String) in
            guard let (code, shifted) = keyPosition(character) else {
                throw NativeInteractionFailure(code: "keyboard_character_unsupported", message: "\"\(character)\" has no key on a standard keyboard, so it cannot be typed as keystrokes. Nothing was sent.")
            }
            return (code, shifted, ["\n", "\r", "\r\n", "\t"].contains(character) ? "" : String(character))
        }
        for (code, shifted, payload) in strokes {
            if shifted { try shift(true) }
            let flags: CGEventFlags = shifted ? .maskShift : []
            try key(code, down: true, flags: flags, text: payload.isEmpty ? nil : payload)
            try key(code, down: false, flags: flags, text: nil)
            if shifted { try shift(false) }
        }
        return .init(source: source, events: events, kind: "keyboard_text", textUnits: text.utf16.count, delays: delays)
    }

    static func keyPosition(_ character: Character) -> (CGKeyCode, Bool)? {
        switch character {
        case "\n", "\r", "\r\n": return (36, false)
        case "\t": return (48, false)
        case " ": return (49, false)
        default: break
        }
        let text = String(character)
        if text.count == 1, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII {
            if let code = codes[text] { return (code, false) }
            let lower = text.lowercased()
            if lower != text, let code = codes[lower] { return (code, true) }
            if let base = shiftedSymbols[text], let code = codes[base] { return (code, true) }
        }
        return nil
    }

    private static let shiftedSymbols: [String: String] = [
        "!":"1","@":"2","#":"3","$":"4","%":"5","^":"6","&":"7","*":"8","(":"9",")":"0",
        "_":"-","+":"=","{":"[","}":"]","|":"\\",":":";","\"":"'","<":",",">":".","?":"/","~":"`",
    ]

    private static func stroke(code: CGKeyCode, flags: CGEventFlags) throws -> (CGEventSource, [CGEvent]) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw NativeInteractionFailure(code: "keyboard_input_unavailable", message: "Native keyboard events could not be created.")
        }
        // A shortcut carries its modifiers on the primary event. It does not
        // press/release the user's physical modifier keys or share HID state.
        down.flags = flags; up.flags = flags
        up.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
        return (source, [down, up])
    }

    private static let codes: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
        "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,
        "=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
        "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,
        "l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
        "tab":48,"space":49,"`":50,"delete":51,"backspace":51,"escape":53,"esc":53,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "home":115,"end":119,"pageup":116,"pagedown":121,"forward_delete":117,
        "arrow_left":123,"left":123,"arrow_right":124,"right":124,"arrow_down":125,"down":125,"arrow_up":126,"up":126,
    ]
}

struct NativeInputDelivery: Encodable {
    let trace_id: String
    let target_pid: pid_t
    let target_window_id: CGWindowID?
    let receiver_id: String?
    let kind: String
    let source_state: Int64
    let source_kind = "private"
    let text_utf16_count: Int?
    let foreground_pid_before: pid_t?
    var foreground_pid_after: pid_t?
    var watched_pids: [pid_t]
    var received_pids: [pid_t] = []
    var received_event_count = 0
    var posted_event_count = 0
    var observer_available = true
    var violation = false
    var target_delivery_observed: Bool { received_pids.contains(target_pid) }
}

// Stores metadata only for exact tags created by this dispatcher. A normal
// user event is ignored before its key, flags, Unicode or other data is read.
final class NativeInputLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int64: NativeInputDelivery] = [:]
    private var tags: [String: Int64] = [:]
    private var order: [Int64] = []
    private var isolationFailure = false

    func begin(target: pid_t, window: CGWindowID?, receiver: String?, plan: NativeInputPlan, foreground: pid_t?) throws -> (Int64, String) {
        lock.lock(); defer { lock.unlock() }
        guard !isolationFailure else { throw NativeInteractionFailure(code: "input_isolation_violation", message: "An earlier input event reached another app. Input dispatch remains stopped.") }
        var tag: Int64
        repeat { tag = Int64.random(in: 1...Int64.max) } while records[tag] != nil
        let id = UUID().uuidString
        records[tag] = NativeInputDelivery(trace_id:id,target_pid:target,target_window_id:window,receiver_id:receiver,kind:plan.kind,
            source_state:Int64(plan.source.sourceStateID.rawValue),text_utf16_count:plan.textUnits,
            foreground_pid_before:foreground,watched_pids:Array(Set([target]+(foreground.map{[$0]} ?? []))).sorted())
        tags[id] = tag; order.append(tag)
        if order.count > 256 { let expired=order.removeFirst(); if let r=records.removeValue(forKey:expired){tags.removeValue(forKey:r.trace_id)} }
        return (tag,id)
    }
    func observe(tag: Int64, deliveredTo pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard var record=records[tag] else {return}
        if !record.received_pids.contains(pid){record.received_pids.append(pid);record.received_pids.sort()}
        record.received_event_count += 1
        if pid != record.target_pid {record.violation=true;isolationFailure=true}
        records[tag]=record
    }
    func posted(_ id: String) { lock.lock();defer{lock.unlock()};if let tag=tags[id]{records[tag]?.posted_event_count += 1} }
    func watching(_ id: String, pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard let tag = tags[id], var record = records[tag], !record.watched_pids.contains(pid) else { return }
        record.watched_pids.append(pid)
        record.watched_pids.sort()
        records[tag] = record
    }
    func observerLost(pid: pid_t) {lock.lock();defer{lock.unlock()};for tag in order where records[tag]?.watched_pids.contains(pid)==true{records[tag]?.observer_available=false}}
    func receipt(_ id: String, foreground: pid_t?) -> NativeInputDelivery? {
        lock.lock();defer{lock.unlock()};guard let tag=tags[id],var r=records[tag] else{return nil}
        r.foreground_pid_after=foreground;records[tag]=r;return r
    }
}

private final class NativeInputObserver: @unchecked Sendable {
    let pid: pid_t
    private let ledger: NativeInputLedger
    private let lock=NSLock()
    private let ready=DispatchSemaphore(value:0)
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopped=false
    init(pid: pid_t, ledger: NativeInputLedger){self.pid=pid;self.ledger=ledger}
    func start() throws {
        let thread=Thread{[self] in
            let callback:CGEventTapCallBack={_,kind,event,context in
                guard let context else{return Unmanaged.passUnretained(event)}
                let observer=Unmanaged<NativeInputObserver>.fromOpaque(context).takeUnretainedValue()
                if kind == .tapDisabledByTimeout || kind == .tapDisabledByUserInput {observer.ledger.observerLost(pid:observer.pid)}
                else {observer.ledger.observe(tag:event.getIntegerValueField(.eventSourceUserData),deliveredTo:observer.pid)}
                return Unmanaged.passUnretained(event)
            }
            let mask=NativeInputPlan.observedTypes.reduce(0){$0|(1 << $1.rawValue)}
            let tap=CGEvent.tapCreateForPid(pid:pid,place:.tailAppendEventTap,options:.listenOnly,eventsOfInterest:CGEventMask(mask),callback:callback,
                userInfo:Unmanaged.passUnretained(self).toOpaque())
            lock.lock();port=tap;loop=CFRunLoopGetCurrent();let cancelled=stopped;lock.unlock()
            if let tap,!cancelled {
                CFRunLoopAddSource(CFRunLoopGetCurrent(),CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0),.commonModes)
                ready.signal();CFRunLoopRun();CFMachPortInvalidate(tap)
            } else {ready.signal();if let tap{CFMachPortInvalidate(tap)}}
        }
        thread.name="OpenComputerUse own-input receipt observer";thread.start()
        guard ready.wait(timeout:.now()+2) == .success else{stop();throw unavailable()}
        lock.lock();let installed=port != nil && !stopped;lock.unlock()
        guard installed else{stop();throw unavailable()}
    }
    func available()->Bool{lock.lock();defer{lock.unlock()};return port.map{!stopped && CGEvent.tapIsEnabled(tap:$0)} ?? false}
    private func unavailable()->NativeInteractionFailure{.init(code:"input_observer_unavailable",message:"The passive input-delivery observer is unavailable. No input was sent.")}
    func stop(){lock.lock();stopped=true;let port=port;let loop=loop;lock.unlock();if let port{CFMachPortInvalidate(port)};if let loop{CFRunLoopStop(loop)}}
    deinit{stop()}
}

final class NativeKeyboardInput: @unchecked Sendable {
    static let shared=NativeKeyboardInput()
    let ledger=NativeInputLedger()
    private var observers:[pid_t:(NativeProcessIdentity,NativeInputObserver)]=[:]
    private var journal:URL?
    private let journalQueue=DispatchQueue(label:"OpenComputerUse input-audit journal")
    func configureJournal(_ url:URL){journal=url}
    func send(_ plan:NativeInputPlan,pid:pid_t,window:CGWindowID?,receiver:String?,validate:() throws -> Void) throws -> String {
        guard CGPreflightPostEventAccess() else{throw NativeInteractionFailure(code:"input_permission_required",message:"macOS event-posting permission is unavailable. No input was sent.")}
        let foreground=NativeAppTarget.frontmostPID()
        guard let identity=try NativeProcessIdentity.read(pid) else{throw NativeInteractionFailure(code:"native_target_changed",message:"The input target exited.")}
        for watched in Set([pid]+(foreground.map{[$0]} ?? [])) {try watch(watched)}
        try validate()
        let(tag,id)=try ledger.begin(target:pid,window:window,receiver:receiver,plan:plan,foreground:foreground)
        // Only posted input lets an app activate itself; watch exactly this window.
        ForegroundGuard.shared?.arm(target:pid); defer{ForegroundGuard.shared?.settle()}
        plan.bind(pid:pid,tag:tag)
        try record(id,stage:"prepared")
        let releases=plan.releases
        var posted=Set<Int>()
        do{
            for(index,event)in plan.events.enumerated() {
                if index<plan.delays.count,plan.delays[index]>0 {
                    // Gestures and paced keystrokes: wait in small steps and keep
                    // checking the receiver, so a cancel or a changed target stops
                    // the sequence (held keys and buttons are released below).
                    let until=Date(timeIntervalSinceNow:plan.delays[index])
                    while Date()<until{Thread.sleep(forTimeInterval:min(0.01,max(0,until.timeIntervalSinceNow)))}
                    try validate()
                }
                guard try NativeProcessIdentity.read(pid)==identity else{throw NativeInteractionFailure(code:"native_target_changed",message:"The input target process changed before dispatch.")}
                if NativeInputPlan.downTypes.contains(event.type) {
                    try validate()
                    let currentForeground = NativeAppTarget.frontmostPID()
                    if let currentForeground { try watch(currentForeground); ledger.watching(id, pid: currentForeground) }
                    // Observer setup may yield. Check the retained receiver again
                    // afterward; foreground status itself does not grant or deny.
                    try record(id, stage: "ready")
                    try validate()
                }
                // Timed sequences carry the time they are posted, so receivers
                // that measure holds and swipe velocity see the real timing.
                if !plan.delays.isEmpty,let now=CGEvent(source:nil)?.timestamp{event.timestamp=now}
                event.postToPid(pid);ledger.posted(id);posted.insert(index)
            }
        }catch{
            if (try? NativeProcessIdentity.read(pid))==identity {
                // Never leave a key, modifier or button logically held in the target.
                // A held button is released where the pointer last was, not at
                // the gesture's unreached end.
                let last=posted.max().map{plan.events[$0]}
                for(press,release)in releases.sorted(by:{$0.key>$1.key}) where posted.contains(press) && !posted.contains(release) {
                    let event=plan.events[release]
                    if [.leftMouseUp,.rightMouseUp].contains(event.type),let last{event.location=last.location}
                    if !plan.delays.isEmpty,let now=CGEvent(source:nil)?.timestamp{event.timestamp=now}
                    event.postToPid(pid);ledger.posted(id)
                }
            }
            try? record(id,stage:"dispatch_error")
            throw NativeKeyboardDispatchFailure(traceID:id,cause:error)
        }
        do{try record(id,stage:"posted")}catch{throw NativeKeyboardDispatchFailure(traceID:id,cause:error)}
        return id
    }
    private func watch(_ pid:pid_t)throws{
        guard let identity=try NativeProcessIdentity.read(pid) else{throw NativeInteractionFailure(code:"input_observer_unavailable",message:"An input observer process exited before dispatch.")}
        if let(existing,observer)=observers[pid],existing==identity,observer.available(){return}
        observers.removeValue(forKey:pid)?.1.stop()
        let observer=NativeInputObserver(pid:pid,ledger:ledger);try observer.start();observers[pid]=(identity,observer)
    }
    func receipts(_ ids:[String])->[NativeInputDelivery]{
        let foreground=NativeAppTarget.frontmostPID()
        return ids.compactMap{id in try? record(id,stage:"observed");return ledger.receipt(id,foreground:foreground)}
    }
    func probe(pid:pid_t)throws->[String:Any]{
        defer{stopObservers()}
        let foreground=NativeAppTarget.frontmostPID()
        for watched in Set([pid]+(foreground.map{[$0]} ?? [])){try watch(watched)}
        var result: [String: Any] = ["observer_available": true, "watched_pids": observers.keys.sorted(), "input_posted": false]
        if let foreground { result["foreground_pid"] = foreground }
        return result
    }
    func stopObservers(){for(_,observer)in observers.values{observer.stop()};observers.removeAll()}
    private func record(_ id:String,stage:String)throws{
        guard let journal,let receipt=ledger.receipt(id,foreground:NativeAppTarget.frontmostPID()),
              let encoded=try? JSONEncoder().encode(receipt),
              let object=try? JSONSerialization.jsonObject(with:encoded) as? [String:Any],
              let line=try? JSONSerialization.data(withJSONObject:["stage":stage,"receipt":object,"timestamp_ms":UInt64(Date().timeIntervalSince1970*1000)]) else{
            throw NativeInteractionFailure(code:"input_audit_unavailable",message:"The private input audit journal could not be prepared.")
        }
        try journalQueue.sync{
                if !FileManager.default.fileExists(atPath:journal.path){FileManager.default.createFile(atPath:journal.path,contents:nil,attributes:[.posixPermissions:0o600])}
                let attributes=try FileManager.default.attributesOfItem(atPath:journal.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.ownerAccountID] as? NSNumber)?.uint32Value==getuid() else{
                    throw NativeInteractionFailure(code:"input_audit_unavailable",message:"The input audit journal must be a private regular file owned by this user.")
                }
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
                let handle=try FileHandle(forWritingTo:journal);defer{try? handle.close()}
                try handle.seekToEnd();try handle.write(contentsOf:line+Data([10]))
        }
    }
}

struct NativeKeyboardDispatchFailure:Error,LocalizedError{
    let traceID:String
    let cause:Error
    var errorDescription:String?{cause.localizedDescription}
}
