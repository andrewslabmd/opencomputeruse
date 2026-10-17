import AppKit
import WebKit
import UniformTypeIdentifiers

final class ProbeWindow: NSWindow {
    var onShortcut: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            onShortcut?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    var window: NSWindow!
    var secondary: NSWindow!
    var shortcutWindow = 0
    var submittedText: String?
    var web: WKWebView!
    var panel: NSSavePanel?
    var saves = [[String: Any]]()
    var counter = 0
    var webState: [String: Any] = [:]
    var resignations = 0
    func record(_ extra: [String: Any] = [:]) {
        var state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
            "active": NSApp.isActive, "resignations": resignations,
            "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "saves": saves, "panel": panel?.windowNumber ?? 0, "web": webState,
            "key_window": NSApp.keyWindow?.windowNumber ?? 0, "secondary_window": secondary?.windowNumber ?? 0,
            "shortcut_window": shortcutWindow,
            "directory": panel?.directoryURL?.path ?? "", "filename": panel?.nameFieldStringValue ?? ""]
        extra.forEach { state[$0.key] = $0.value }
        if let submittedText {state["submitted_text"]=submittedText}
        try? JSONSerialization.data(withJSONObject: state).write(to: output, options: .atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:nil) { _ in
            self.resignations += 1; self.record()
        }
        secondary = ProbeWindow(contentRect: NSRect(x:700,y:120,width:350,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        secondary.title = "Secondary native document"
        let editor=NSTextField(frame:NSRect(x:20,y:30,width:280,height:30))
        editor.stringValue="Secondary editor"; editor.setAccessibilityIdentifier("secondary-editor")
        editor.target=self;editor.action=#selector(submitted(_:))
        secondary.contentView!.addSubview(editor)
        (secondary as! ProbeWindow).onShortcut = {self.shortcutWindow=self.secondary.windowNumber;self.record()}
        secondary.orderFront(nil)
        window = ProbeWindow(contentRect: NSRect(x: 120, y: 120, width: 520, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        (window as! ProbeWindow).onShortcut = {self.shortcutWindow=self.window.windowNumber;self.record()}
        window.title = "Native contract probe"
        let button = NSButton(title: "Open save panel", target: self, action: #selector(save))
        button.frame = NSRect(x: 20, y: 495, width: 180, height: 30)
        window.contentView!.addSubview(button)
        web = WKWebView(frame: NSRect(x: 10, y: 10, width: 500, height: 470))
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        let rows = (1...90).map { "<p>Entry \($0) <a href='https://example.com/item/\($0)'>Destination \($0)</a></p>" }.joined()
        web.loadHTMLString("<html><body><input aria-label='Web editor' value='Original'><div style='width:1600px'>\(rows)</div></body></html>", baseURL: URL(string: "https://example.com"))
        window.orderFront(nil)
        record()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.web.evaluateJavaScript("({x:scrollX,y:scrollY,text:document.querySelector('input').value})") { value, error in
                if let value = value as? [String: Any] { self.webState = value }
                self.record()
            }
        }
    }
    @objc func submitted(_ sender:NSTextField){submittedText=sender.stringValue;record()}
    @objc func save() {
        guard panel == nil else { return }
        counter += 1
        let p = NSSavePanel()
        panel = p
        p.allowedContentTypes = [.rtf]
        p.nameFieldStringValue = "Original \(counter).rtf"
        p.directoryURL = output.deletingLastPathComponent()
        p.beginSheetModal(for: window) { response in
            let url = p.url
            if response == .OK, let url {
                try? Data("{\\rtf1 Native save acceptance}".utf8).write(to: url)
            }
            self.saves.append(["response": response.rawValue, "url": url?.path ?? "", "name": p.nameFieldStringValue])
            self.panel = nil
            self.record()
        }
        record()
    }
}
let delegate = Probe()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
