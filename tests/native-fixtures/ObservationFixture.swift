// Owned opt-in native observation/lifecycle acceptance fixture. Never activates NSApp.
import AppKit

private final class SlowElement: NSAccessibilityElement {
    override func accessibilityLabel() -> String? {
        Thread.sleep(forTimeInterval: 0.02)
        return super.accessibilityLabel()
    }
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mode: String
    let state: URL
    var windows: [NSWindow] = []
    var elements: [NSAccessibilityElement] = []
    init(mode: String, state: String) { self.mode = mode; self.state = URL(fileURLWithPath: state) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = makeWindow(title: "OCU observation \(mode)", y: 160)
        let content = window.contentView!
        let quit = NSButton(title: "Finish fixture", target: self, action: #selector(finish))
        quit.frame = NSRect(x: 20, y: 20, width: 150, height: 35)
        content.addSubview(quit)
        if mode == "large" || mode == "slow" {
            let group = NSView(frame: NSRect(x: 10, y: 70, width: 400, height: 180))
            group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
            group.setAccessibilityLabel("Large document content")
            content.addSubview(group)
            let count = mode == "large" ? 6500 : 2000
            for i in 0..<count {
                let e = mode == "slow" ? SlowElement() : NSAccessibilityElement()
                e.setAccessibilityRole(.staticText); e.setAccessibilityLabel("Owned content \(i)")
                e.setAccessibilityFrame(NSRect(x: 130, y: 200 + i * 15, width: 200, height: 12))
                e.setAccessibilityParent(group); elements.append(e)
            }
            group.setAccessibilityChildren(elements)
            _ = makeWindow(title: "OCU second window \(mode)", y: 500)
        }
        if mode == "text-style" {
            let editor = NSTextView(frame: NSRect(x: 20, y: 70, width: 380, height: 160))
            let text = NSMutableAttributedString(string: "Plain marked")
            text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 6, length: 6))
            editor.textStorage?.setAttributedString(text); content.addSubview(editor)
            editor.setSelectedRange(NSRange(location: 6, length: 6)); window.makeFirstResponder(editor)
        }
        write("ready")
    }
    func makeWindow(title: String, y: Int) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 120, y: y, width: 450, height: 280),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.delegate = self; w.isReleasedWhenClosed = false
        w.orderBack(nil); windows.append(w); return w
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        mode == "close-exit"
    }
    func windowWillClose(_ notification: Notification) { write("window closed") }
    @objc func finish() {
        write("finish invoked")
        DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "button-accepted-exit" ? 0.7 : 0.04)) { NSApp.terminate(nil) }
    }
    func write(_ event: String) {
        let data: [String: Any] = ["pid": getpid(), "mode": mode, "event": event,
            "visible_windows": windows.filter(\.isVisible).map(\.title)]
        try? JSONSerialization.data(withJSONObject: data).write(to: state, options: .atomic)
    }
}
@main private enum Main {
    @MainActor static var fixture: Fixture?
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let f = Fixture(mode: CommandLine.arguments[1], state: CommandLine.arguments[2])
        fixture = f; app.delegate = f; app.run()
    }
}
