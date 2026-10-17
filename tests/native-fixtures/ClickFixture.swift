import AppKit

// Opt-in live fixture for repeated/modified pointer clicks, named Accessibility
// actions and the application list. It records what AppKit actually delivered:
// mouse-down click counts and the modifiers carried by each event, table
// selection, the table's double action, stepper value and custom actions. It
// never activates itself; it runs as an accessory app launched in the background.
final class ClickPad: NSView {
    var onEvent: ((NSEvent) -> Void)?
    var onPress: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onEvent?(event) }
    override func draw(_ dirtyRect: NSRect) { NSColor.systemTeal.setFill(); dirtyRect.fill() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Click pad" }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

final class ArchiveCard: NSView {
    var onArchive: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) { NSColor.systemOrange.setFill(); dirtyRect.fill() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Archive card" }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Archive") { [weak self] in self?.onArchive?(); return true }]
    }
}

final class Fixture: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let rows = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
    var window: NSWindow!
    let table = NSTableView()
    let stepper = NSStepper()
    let editor = NSTextField(string: "")
    var clicks: [[String: Any]] = []
    var presses = 0, archives = 0, menuOpened = 0, menuClosed = 0
    var doubleClickedRows: [Int] = []
    var foregroundChanges: [[String: Any]] = []
    var lastFront: pid_t = 0
    let pointerAtStart = NSEvent.mouseLocation

    static func names(_ flags: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.command, "cmd"), (.shift, "shift"), (.option, "option"), (.control, "control")]
            .filter { flags.contains($0.0) }.map(\.1)
    }
    func record() {
        let state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber, "active": NSApp.isActive,
            "clicks": clicks, "presses": presses, "archives": archives, "menu_opened": menuOpened, "menu_closed": menuClosed,
            "selection": Array(table.selectedRowIndexes), "double_clicked_rows": doubleClickedRows,
            "stepper": stepper.integerValue, "editor": editor.stringValue, "foreground_changes": foregroundChanges,
            "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "pointer_moved": NSEvent.mouseLocation != pointerAtStart,
        ]
        try? JSONSerialization.data(withJSONObject: state).write(to: output, options: .atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 440, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OCU click fixture"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let pad = ClickPad(frame: NSRect(x: 20, y: 300, width: 180, height: 80))
        pad.onEvent = { event in
            self.clicks.append(["count": event.clickCount, "modifiers": Self.names(event.modifierFlags),
                "global_modifiers": Self.names(NSEvent.modifierFlags)]); self.record()
        }
        pad.onPress = { self.presses += 1; self.record() }
        let menu = NSMenu(title: "Pad menu"); menu.addItem(withTitle: "Pad item", action: nil, keyEquivalent: "")
        menu.delegate = self
        pad.menu = menu
        content.addSubview(pad)
        let card = ArchiveCard(frame: NSRect(x: 220, y: 300, width: 200, height: 80))
        card.onArchive = { self.archives += 1; self.record() }
        content.addSubview(card)
        stepper.frame = NSRect(x: 20, y: 250, width: 30, height: 30)
        stepper.minValue = 0; stepper.maxValue = 10; stepper.integerValue = 3
        stepper.setAccessibilityLabel("Fixture stepper")
        content.addSubview(stepper)
        editor.frame = NSRect(x: 70, y: 250, width: 350, height: 26)
        editor.setAccessibilityLabel("Fixture editor")
        content.addSubview(editor)
        let column = NSTableColumn(identifier: .init("names")); column.width = 380
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 28
        table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel("Fixture table")
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 400, height: 200)); scroll.documentView = table
        content.addSubview(scroll)
        table.reloadData()
        window.orderFront(nil)
        lastFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        record()
        // Foreground audit every 10 ms for the whole run.
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            if front != self.lastFront {
                self.foregroundChanges.append(["from": self.lastFront, "to": front, "at": Date().timeIntervalSince1970])
                self.lastFront = front; self.record()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.record() }
    }
    @objc func doubleClicked() { doubleClickedRows.append(table.clickedRow); record() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: rows[row]); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { record() }
}

extension Fixture: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuOpened += 1; record() }
    func menuDidClose(_ menu: NSMenu) { menuClosed += 1; record() }
}

let delegate = Fixture()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
