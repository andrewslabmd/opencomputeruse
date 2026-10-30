import AppKit
import Foundation

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private let resultURL: URL
    private var initialPointer = NSEvent.mouseLocation
    private var initialFrontmost: pid_t?
    private let previousApplication = NSWorkspace.shared.frontmostApplication
    private var window: NSWindow?
    private var panel: NSPanel?
    private var visualOverlay: NSWindow?
    private var textField: NSTextField?
    private var slider: NSSlider?
    private var scrollView: NSScrollView?
    private var panelActionPerformed = false
    private var committed = false
    private var ready = false

    init(resultPath: String) {
        self.resultURL = URL(fileURLWithPath: resultPath)
    }

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Computer Use Fixture"
        window.setAccessibilityRole(.window)
        window.setFrameOrigin(NSPoint(x: 160, y: 180))

        let textField = NSTextField(frame: NSRect(x: 40, y: 155, width: 320, height: 28))
        textField.placeholderString = "Type here"
        textField.setAccessibilityLabel("Fixture Input")
        window.contentView?.addSubview(textField)

        let button = NSButton(frame: NSRect(x: 380, y: 153, width: 100, height: 32))
        button.title = "Commit"
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(commit)
        button.setAccessibilityLabel("Commit")
        window.contentView?.addSubview(button)

        let slider = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 40, y: 105, width: 300, height: 24)
        slider.setAccessibilityLabel("Fixture Level")
        window.contentView?.addSubview(slider)
        let begin = NSButton(frame: NSRect(x: 365, y: 100, width: 110, height: 30))
        begin.title = "Begin Test"
        begin.target = self
        begin.action = #selector(beginTest)
        window.contentView?.addSubview(begin)

        let scrollView = NSScrollView(frame: NSRect(x: 40, y: 20, width: 300, height: 64))
        scrollView.hasVerticalScroller = true
        scrollView.setAccessibilityLabel("Fixture Scroll")
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))
        for index in 0 ..< 12 {
            let label = NSTextField(labelWithString: "Scrollable row \(index + 1)")
            label.frame = NSRect(x: 8, y: 8 + (index * 25), width: 220, height: 20)
            document.addSubview(label)
        }
        scrollView.documentView = document
        scrollView.contentView.scroll(to: .zero)
        window.contentView?.addSubview(scrollView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Fixture Transient Panel"
        panel.setAccessibilityRole(.window)
        panel.setFrameOrigin(NSPoint(x: 620, y: 360))
        panel.becomesKeyOnlyIfNeeded = true
        let panelLabel = NSTextField(labelWithString: "Separate application window")
        panelLabel.frame = NSRect(x: 20, y: 65, width: 200, height: 22)
        panel.contentView?.addSubview(panelLabel)
        let panelButton = NSButton(frame: NSRect(x: 45, y: 20, width: 150, height: 32))
        panelButton.title = "Panel Action"
        panelButton.bezelStyle = .rounded
        panelButton.target = self
        panelButton.action = #selector(performPanelAction)
        panelButton.setAccessibilityLabel("Fixture Panel Action")
        panel.contentView?.addSubview(panelButton)

        let visualOverlay = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        visualOverlay.backgroundColor = .systemPurple
        visualOverlay.setFrameOrigin(NSPoint(x: 420, y: 370))
        visualOverlay.setAccessibilityRole(.unknown)
        let visualLabel = NSTextField(labelWithString: "Capture-only overlay")
        visualLabel.textColor = .white
        visualLabel.frame = NSRect(x: 14, y: 22, width: 132, height: 20)
        visualOverlay.contentView?.addSubview(visualLabel)

        self.window = window
        self.panel = panel
        self.visualOverlay = visualOverlay
        self.textField = textField
        self.slider = slider
        self.scrollView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.addChildWindow(panel, ordered: .above)
        window.addChildWindow(visualOverlay, ordered: .above)
        panel.orderFrontRegardless()
        visualOverlay.orderFrontRegardless()
        // Initialize AppKit's Accessibility window objects once, then return
        // the fixture to the background before any Computer Use assertion.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.deactivate()
            self.previousApplication?.activate(options: [.activateIgnoringOtherApps])
            self.ready = true
            self.writeState()
        }
        Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated { self.writeState() }
        }
    }

    @objc private func performPanelAction() {
        self.panelActionPerformed = true
    }
    @objc private func beginTest() {
        self.initialPointer = NSEvent.mouseLocation
        self.initialFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        self.writeState()
    }

    @objc private func commit() {
        self.committed = true
        self.writeState()
    }

    private func writeState() {
        let payload: [String: Any] = [
            "ready": self.ready,
            "committed": self.committed,
            "text": self.textField?.stringValue ?? "",
            "level": self.slider?.doubleValue ?? -1,
            "scrollOffset": self.scrollView?.contentView.bounds.origin.y ?? -1,
            "appActive": NSApp.isActive,
            "pointerMoved": self.initialPointer != NSEvent.mouseLocation,
            "frontmostUnchanged": self.initialFrontmost == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "frontmostBefore": self.initialFrontmost ?? -1,
            "frontmostAfter": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "panelActionPerformed": self.panelActionPerformed,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: self.resultURL, options: .atomic)
        }
    }
}

@main
private enum ComputerUseFixture {
    @MainActor private static var delegate: FixtureDelegate?

    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate(resultPath: CommandLine.arguments[1])
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
