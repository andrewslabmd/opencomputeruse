import AppKit
import QuartzCore

// On-screen agent cursors. The host publishes, per agent, the window and point
// of its latest action (cursors.json). Each agent gets one transparent,
// click-through panel stacked directly above its target window, so windows in
// front of that window also cover the cursor and it never floats over
// unrelated apps. The panel draws a highlight around the window, the pointer
// in the agent's color with its name, and a ripple on clicks. OCU's own
// observations and screenshots capture only the target app's windows, so the
// overlay never appears in what an agent sees. While an agent is acting, its
// pointer glides to each target; while it thinks between calls, it bounces.
struct AgentCursor: Decodable, Equatable {
    let client: String
    let name: String
    let slot: Int
    let pid: Int32
    let window_id: UInt32
    let x: Double
    let y: Double
    let kind: String
    let to_x: Double?
    let to_y: Double?
    let at: Double
    let busy: Bool?
}

@MainActor
final class CursorOverlay {
    private let file: URL
    private var panels: [String: AgentCursorPanel] = [:]
    private var timer: Timer?
    private var lastData: Data?
    private var cursors: [AgentCursor] = []
    var enabled = true { didSet { if !enabled { clear() } } }

    init(runtime: URL) { file = runtime.appendingPathComponent("cursors.json") }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func clear() {
        panels.values.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll(); cursors = []; lastData = nil
    }

    private func tick() {
        guard enabled else { return }
        if let data = try? Data(contentsOf: file) {
            if data != lastData { lastData = data; cursors = (try? JSONDecoder().decode([AgentCursor].self, from: data)) ?? [] }
        } else { cursors = []; lastData = nil }
        let live = Set(cursors.map(\.client))
        for (client, panel) in panels where !live.contains(client) { panel.orderOut(nil); panel.close(); panels[client] = nil }
        guard !cursors.isEmpty else { return }
        // Front-to-back list of on-screen windows: minimized, hidden and other-Space
        // windows are absent, and their cursor hides with them.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for cursor in cursors {
            let panel = panels[cursor.client] ?? AgentCursorPanel()
            panels[cursor.client] = panel
            panel.update(cursor, windows: windows)
        }
    }
}

final class AgentCursorPanel: NSPanel {
    private let canvas = AgentCursorView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true; isReleasedWhenClosed = false; animationBehavior = .none
        level = .normal
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = canvas
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(_ cursor: AgentCursor, windows: [[String: Any]]) {
        func number(_ info: [String: Any]) -> UInt32 { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0 }
        guard let index = windows.firstIndex(where: { number($0) == cursor.window_id }),
              let raw = windows[index][kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
              bounds.width > 0, bounds.height > 0 else {
            if isVisible { orderOut(nil) }
            return
        }
        // Window Server bounds are top-left based; AppKit frames are bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        if self.frame != frame { setFrame(frame, display: false) }
        canvas.show(cursor, windowOrigin: bounds.origin)
        // Directly above the target: anything in front of the target stays in front.
        let above = index > 0 ? number(windows[index - 1]) : nil
        if !isVisible || above != UInt32(windowNumber) { order(.above, relativeTo: Int(cursor.window_id)) }
    }
}

final class AgentCursorView: NSView {
    static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemGreen, .systemPink, .systemTeal]
    private let border = CAShapeLayer()
    /// Pointer and name tag move and bounce together; the marker's position is the tip.
    private let marker = CALayer()
    private let pointer = CALayer()
    private var activity: Bool?
    private let label = CATextLayer()
    private let labelBackground = CALayer()
    private var shown: AgentCursor?
    private var color = NSColor.systemBlue
    // Phosphor navigation-arrow (fill), as in the app icon; see THIRD_PARTY_NOTICES.md.
    private static let arrowPath = "M248,121.58a15.76,15.76,0,0,1-11.29,15l-.2.06-78,21.84-21.84,78-.06.2a15.77,15.77,0,0,1-15,11.29h-.3a15.77,15.77,0,0,1-15.07-10.67L41,61.41a1,1,0,0,1-.05-.16A16,16,0,0,1,61.25,40.9l.16.05,175.92,65.26A15.78,15.78,0,0,1,248,121.58Z"
    private static let pointerSize: CGFloat = 26
    /// The arrow's tip within its 256-unit box, scaled to the layer.
    private static let tip = CGPoint(x: 46 * pointerSize / 256, y: 46 * pointerSize / 256)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        border.fillColor = nil; border.lineWidth = 2
        pointer.bounds = CGRect(x: 0, y: 0, width: Self.pointerSize, height: Self.pointerSize)
        pointer.anchorPoint = CGPoint(x: Self.tip.x / Self.pointerSize, y: Self.tip.y / Self.pointerSize)
        pointer.shadowColor = NSColor.black.cgColor; pointer.shadowOpacity = 0.35; pointer.shadowRadius = 2; pointer.shadowOffset = CGSize(width: 0, height: 1)
        labelBackground.cornerRadius = 7
        label.fontSize = 11; label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.foregroundColor = NSColor.white.cgColor; label.alignmentMode = .center
        labelBackground.addSublayer(label)
        pointer.position = .zero
        marker.addSublayer(labelBackground); marker.addSublayer(pointer)
        for sublayer in [border, marker] { layer?.addSublayer(sublayer) }
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [pointer, label, labelBackground, border] { sublayer.contentsScale = scale }
    }

    func show(_ cursor: AgentCursor, windowOrigin: CGPoint) {
        let first = shown == nil
        let moved = shown?.at != cursor.at
        if first || shown?.slot != cursor.slot { applyColor(Self.palette[cursor.slot % Self.palette.count]) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
        label.string = cursor.name
        let textWidth = (cursor.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        labelBackground.bounds = CGRect(x: 0, y: 0, width: ceil(textWidth) + 14, height: 18)
        label.frame = labelBackground.bounds.insetBy(dx: 0, dy: 2)
        labelBackground.position = CGPoint(x: 14 + labelBackground.bounds.width / 2, y: 24)
        CATransaction.commit()
        setActivity(busy: cursor.busy == true)

        let point = CGPoint(x: cursor.x - windowOrigin.x, y: cursor.y - windowOrigin.y)
        // Window moves keep the cursor in place without animation; a new action glides there.
        CATransaction.begin()
        CATransaction.setDisableActions(first || !moved)
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        place(point)
        CATransaction.commit()
        if moved && !first, let toX = cursor.to_x, let toY = cursor.to_y {
            // A drag: glide on from the start to the end point.
            let end = CGPoint(x: toX - windowOrigin.x, y: toY - windowOrigin.y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                CATransaction.begin(); CATransaction.setAnimationDuration(0.4); self?.place(end); CATransaction.commit()
            }
        }
        if moved && ["click", "right_click", "long_press", "open", "perform_action"].contains(cursor.kind) {
            // After the glide, where the action lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.25)) { [weak self] in self?.ripple(at: point) }
        }
        shown = cursor
    }

    private func place(_ point: CGPoint) { marker.position = point }

    /// Thinking between calls: pointer and name tag bounce. Acting: no extra
    /// motion; the glide to each target and the click ripple show the work.
    private func setActivity(busy: Bool) {
        guard activity != busy else { return }
        activity = busy
        marker.removeAnimation(forKey: "activity")
        guard !busy else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, -7, 0, -2.5, 0, 0]; bounce.keyTimes = [0, 0.22, 0.44, 0.56, 0.68, 1]
        bounce.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn), .init(name: .linear)]
        bounce.duration = 1.1; bounce.repeatCount = .infinity
        marker.add(bounce, forKey: "activity")
    }

    private func applyColor(_ color: NSColor) {
        self.color = color
        border.strokeColor = color.withAlphaComponent(0.55).cgColor
        labelBackground.backgroundColor = color.cgColor
        let hex = color.usingColorSpace(.sRGB).map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#0a84ff"
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><path fill=\"\(hex)\" stroke=\"#ffffff\" stroke-width=\"14\" stroke-linejoin=\"round\" d=\"\(Self.arrowPath)\"/></svg>"
        let image = NSImage(data: Data(svg.utf8))
        let scale = window?.backingScaleFactor ?? 2
        pointer.contents = image?.layerContents(forContentsScale: scale)
        pointer.contentsScale = scale
    }

    private func ripple(at point: CGPoint) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
        ring.fillColor = color.withAlphaComponent(0.18).cgColor
        ring.strokeColor = color.cgColor; ring.lineWidth = 2
        ring.position = point; ring.opacity = 0
        layer?.insertSublayer(ring, below: marker)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.3; grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [grow, fade]; group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}
