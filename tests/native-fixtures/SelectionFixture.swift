import AppKit
import Foundation

// Opt-in live fixture: real AppKit selection state, not an AX setter echo.
// It never activates the app or generates physical input.
@MainActor
private final class Fixture: NSObject, NSApplicationDelegate, NSTableViewDataSource,
  NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSCollectionViewDataSource
{
  let output: URL
  let table = NSTableView()
  let outline = NSOutlineView()
  let collection = NSCollectionView()
  let tab = NSTabView()
  let text = NSTextField(string: "Original fixture text")
  var presses = 0
  var window: NSWindow!
  var timer: Timer?
  let labels = ["Alpha", "Beta", "Gamma"]
  let branch = NSString(string: "Branch")
  let leaves = [NSString(string: "Outline Alpha"), NSString(string: "Outline Beta")]
  let beforePointer = NSEvent.mouseLocation
  let beforeForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
  init(_ path: String) { output = URL(fileURLWithPath: path) }
  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 80, y: 60, width: 600, height: 680), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Selection contract fixture"
    window.isReleasedWhenClosed = false
    let content = window.contentView!
    func scroll(_ view: NSView, _ rect: NSRect) {
      let s = NSScrollView(frame: rect)
      s.hasVerticalScroller = true
      s.documentView = view
      content.addSubview(s)
    }
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("names"))
    column.width = 260
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 32
    table.allowsMultipleSelection = true
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Fixture table")
    scroll(table, NSRect(x: 20, y: 550, width: 270, height: 100))
    table.reloadData()
    let oc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
    oc.width = 260
    outline.addTableColumn(oc)
    outline.outlineTableColumn = oc
    outline.headerView = nil
    outline.rowHeight = 32
    outline.dataSource = self
    outline.delegate = self
    outline.setAccessibilityLabel("Fixture outline")
    scroll(outline, NSRect(x: 310, y: 510, width: 270, height: 140))
    outline.reloadData()
    outline.expandItem(branch)
    let flow = NSCollectionViewFlowLayout()
    flow.itemSize = NSSize(width: 160, height: 90)
    flow.minimumInteritemSpacing = 12
    flow.minimumLineSpacing = 12
    collection.collectionViewLayout = flow
    collection.isSelectable = true
    collection.allowsMultipleSelection = true
    collection.dataSource = self
    collection.register(Card.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("card"))
    collection.setAccessibilityLabel("Fixture collection")
    scroll(collection, NSRect(x: 20, y: 280, width: 550, height: 190))
    collection.reloadData()
    tab.frame = NSRect(x: 20, y: 140, width: 270, height: 100)
    for name in ["First tab", "Second tab"] {
      let t = NSTabViewItem(identifier: name)
      t.label = name
      t.view = NSView()
      tab.addTabViewItem(t)
    }
    content.addSubview(tab)
    let button = NSButton(frame: NSRect(x: 330, y: 170, width: 230, height: 40))
    button.title = "Fixture press"
    button.image = NSImage(
      systemSymbolName: "star.fill", accessibilityDescription: "Decorative star")
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(press)
    content.addSubview(button)
    text.frame = NSRect(x: 20, y: 70, width: 550, height: 30)
    text.setAccessibilityLabel("Fixture editor")
    content.addSubview(text)
    window.orderBack(nil)
    timer = Timer.scheduledTimer(
      timeInterval: 0.05, target: self, selector: #selector(save), userInfo: nil, repeats: true)
    save()
  }
  @objc func press() {
    presses += 1
    save()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { labels.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  { cell("Table " + labels[row]) }
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    item == nil ? 1 : ((item as? NSString) == branch ? leaves.count : 0)
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    item == nil ? branch : leaves[index]
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? NSString) == branch
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  { cell(String(describing: item)) }
  func cell(_ title: String) -> NSView {
    let v = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
    let label = NSTextField(labelWithString: title)
    label.frame = NSRect(x: 30, y: 5, width: 220, height: 22)
    v.textField = label
    v.addSubview(label)
    let image = NSImageView(frame: NSRect(x: 4, y: 5, width: 20, height: 20))
    image.image = NSImage(systemSymbolName: "doc", accessibilityDescription: title + " icon")
    v.imageView = image
    v.addSubview(image)
    return v
  }
  func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
    -> Int
  { section == 0 ? 2 : 1 }
  func collectionView(
    _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item = collectionView.makeItem(
      withIdentifier: NSUserInterfaceItemIdentifier("card"), for: indexPath)
    item.textField?.stringValue = "Card \(indexPath.section)-\(indexPath.item)"
    return item
  }
  @objc func save() {
    let state: [String: Any] = [
      "pid": getpid(), "table_rows": Array(table.selectedRowIndexes),
      "outline_rows": Array(outline.selectedRowIndexes),
      "collection_items": collection.selectionIndexPaths.map { [$0.section, $0.item] }.sorted {
        $0.lexicographicallyPrecedes($1)
      }, "tab": tab.indexOfTabViewItem(tab.selectedTabViewItem!), "presses": presses,
      "text": text.stringValue,
      "foreground_unchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier
        == beforeForeground, "pointer_unchanged": NSEvent.mouseLocation == beforePointer,
      "active": NSApp.isActive,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
      try? data.write(to: output, options: .atomic)
    }
  }
}
@MainActor
private final class Card: NSCollectionViewItem {
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    let image = NSImageView(frame: NSRect(x: 45, y: 28, width: 64, height: 56))
    image.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Card picture")
    imageView = image
    view.addSubview(image)
    let text = NSTextField(labelWithString: "")
    text.frame = NSRect(x: 10, y: 4, width: 140, height: 22)
    textField = text
    view.addSubview(text)
  }
}
@main
private enum Main {
  @MainActor static var fixture: Fixture?
  @MainActor static func main() {
    guard CommandLine.arguments.count == 2 else { exit(64) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let f = Fixture(CommandLine.arguments[1])
    fixture = f
    app.delegate = f
    app.run()
  }
}
