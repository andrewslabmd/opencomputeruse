import AppKit
import CoreGraphics

final class ScrollingContent: NSView {
    var phase: CGFloat = 0
    var animated = false
    var colour = NSColor.systemTeal
    override func draw(_ dirtyRect: NSRect) {
        colour.setFill(); bounds.fill()
        guard animated else { return }
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); bounds.insetBy(dx: 18, dy: 18).fill()
        for row in -1..<Int(bounds.height / 38) + 2 {
            let y = CGFloat(row) * 38 + phase.truncatingRemainder(dividingBy: 38)
            (row % 2 == 0 ? NSColor.white : NSColor(calibratedWhite: 0.9, alpha: 1)).setFill()
            NSRect(x: 24, y: y, width: bounds.width - 48, height: 37).fill()
            let text = "Row \(row + Int(phase / 38))   Project activity — background capture measurement   0123456789"
            (text as NSString).draw(at: NSPoint(x: 40, y: y + 9), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
            NSColor.systemBlue.setFill()
            NSRect(x: bounds.width * 0.72, y: y + 9, width: CGFloat((row + 30) % 9 + 1) * 15, height: 18).fill()
        }
    }
}

final class StreamFixture: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let commands = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow!
    var child: NSWindow?, sheet: NSWindow?, popover: NSPopover?, menu: NSMenu?
    let content = ScrollingContent()
    var lastCommand = "", commandError: String?
    var foregroundChanges: [[String: Any]] = []
    var lastFront: pid_t = 0
    var menuOpen = false
    var screen: NSScreen!

    func record() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        let state: [String: Any] = ["pid": pid, "window": window.windowNumber,
            "window_ids": windows.compactMap { $0[kCGWindowNumber as String] },
            "windows": windows, "active": NSApp.isActive, "hidden": NSApp.isHidden,
            "minimized": window.isMiniaturized, "visible": window.isVisible,
            "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
            "screen": [screen.frame.width, screen.frame.height],
            "visible_screen": [screen.visibleFrame.width, screen.visibleFrame.height],
            "animating": content.animated, "sharing": window.sharingType.rawValue,
            "child": child?.windowNumber ?? 0, "popover": popover?.isShown ?? false,
            "sheet": sheet?.windowNumber ?? 0, "menu_open": menuOpen,
            "last_command": lastCommand, "command_error": commandError ?? NSNull() as Any,
            "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "foreground_changes": foregroundChanges]
        try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: output, options: .atomic)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        screen = NSScreen.main!
        let area = screen.visibleFrame
        // The measured dimensions are the entire window, including the title bar.
        let frame = NSRect(x: area.minX, y: area.minY, width: min(1440, area.width), height: min(900, area.height))
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.setFrame(frame, display: false); window.title = "OCU Stream Fixture"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.order(.below, relativeTo: 0)
        lastFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let front = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            self.foregroundChanges.append(["from": self.lastFront, "to": front, "at": Date().timeIntervalSince1970]); self.lastFront = front; self.record()
        }
        let poll = Timer(timeInterval: 0.02, repeats: true) { _ in self.poll() }
        RunLoop.main.add(poll, forMode: .common); RunLoop.main.add(poll, forMode: .eventTracking)
        let stateTimer = Timer(timeInterval: 0.2, repeats: true) { _ in self.record() }
        RunLoop.main.add(stateTimer, forMode: .common); RunLoop.main.add(stateTimer, forMode: .eventTracking)
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { _ in
            if self.content.animated { self.content.phase += 2; self.content.needsDisplay = true }
        }
        record()
    }

    func colourWindow(_ title: String, colour: NSColor, frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false
        let view = ScrollingContent(); view.colour = colour; w.contentView = view
        return w
    }

    func poll() {
        guard let data = try? Data(contentsOf: commands), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = command["id"] as? String, id != lastCommand, let name = command["command"] as? String else { return }
        lastCommand = id; commandError = nil
        switch name {
        case "solid":
            window.orderBack(nil)
            content.animated = false
            let rgb = command["rgb"] as? [Double] ?? [0, 0.65, 0.65]
            content.colour = NSColor(calibratedRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1); content.needsDisplay = true
        case "animate": window.orderBack(nil); content.animated = true
        case "still": window.orderBack(nil); content.animated = false; content.needsDisplay = true
        case "minimize": window.miniaturize(nil)
        case "restore": window.deminiaturize(nil); window.orderBack(nil)
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhideWithoutActivation(); window.orderBack(nil)
        case "resize":
            var frame = window.frame
            frame.size = NSSize(width: command["width"] as? Double ?? 900, height: command["height"] as? Double ?? 600)
            window.setFrame(frame, display: true)
        case "close": window.close()
        case "sharingNone": window.sharingType = .none
        case "sharingReadOnly": window.sharingType = .readOnly
        case "child":
            let w = colourWindow("Magenta child", colour: .systemPink, frame: NSRect(x: window.frame.maxX - 240, y: window.frame.midY, width: 320, height: 220))
            child = w; window.addChildWindow(w, ordered: .above)
        case "closeChild": if let child { window.removeChildWindow(child); child.close(); self.child = nil }
        case "popover":
            let p = NSPopover(); p.behavior = .applicationDefined; p.animates = false
            let vc = NSViewController(); let view = ScrollingContent(frame: NSRect(x: 0, y: 0, width: 320, height: 200)); view.colour = .systemYellow
            vc.view = view; p.contentViewController = vc; p.contentSize = view.frame.size; popover = p
            p.show(relativeTo: NSRect(x: 120, y: content.bounds.midY, width: 2, height: 2), of: content, preferredEdge: .maxX)
        case "closePopover": popover?.close(); popover = nil
        case "sheet":
            let w = colourWindow("Orange sheet", colour: .systemOrange, frame: NSRect(x: 0, y: 0, width: 440, height: 240))
            sheet = w; window.beginSheet(w)
        case "closeSheet": if let sheet { window.endSheet(sheet); sheet.close(); self.sheet = nil }
        case "context":
            guard CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!) >= 5 else { commandError = "HID input in last five seconds"; record(); return }
            let m = NSMenu(title: "Stream fixture menu"); menu = m; m.delegate = self
            for label in ["Fixture context menu", "Magenta marker", "No input is sent"] { m.addItem(withTitle: label, action: nil, keyEquivalent: "") }
            let timer = Timer(timeInterval: 1.2, repeats: false) { _ in m.cancelTracking() }
            RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .common)
            record(); m.popUp(positioning: nil, at: NSPoint(x: 160, y: content.bounds.midY), in: content)
        default: commandError = "Unknown command: \(name)"
        }
        record()
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; record() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; record() }
}

let delegate = StreamFixture()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
