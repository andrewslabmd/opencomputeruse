import AppKit
import SwiftUI
import OCUStream

@MainActor
final class PiPController {
    private final class Viewer {
        let panel: PiPWindow
        var target: StreamTarget?
        var end: StreamEndReason?
        var failure: StreamErrorCode?
        var followsStack = true
        var receivedTarget = false
        init(_ panel: PiPWindow) { self.panel = panel }
    }
    private let runtime: URL
    private let defaults: UserDefaults
    private var viewers: [String: Viewer] = [:]
    private var order: [String] = []
    private var stopped = false
    private var noPermission = false
    var statusItemFrame: CGRect?
    private lazy var client = StreamClient(runtime: runtime, callbackQueue: .main) { [weak self] event in
        MainActor.assumeIsolated { self?.receive(event) }
    }

    init(runtime: URL, defaults: UserDefaults = .standard) { self.runtime = runtime; self.defaults = defaults }

    func watch(_ agent: Agent) {
        if let viewer = viewers[agent.id] { viewer.panel.orderFrontRegardless(); return }
        guard agent.app != nil else { return }
        let panel = PiPWindow(name: agent.name, slot: agent.slot ?? 0)
        let viewer = Viewer(panel); viewers[agent.id] = viewer; order.append(agent.id)
        panel.onClose = { [weak self] in self?.closed(agent.id) }
        panel.onPositionChanged = { [weak self, weak panel] in
            if let panel {
                self?.viewers[agent.id]?.followsStack = false
                self?.placeAfterDrag(panel)
            }
        }
        panel.canvas.onShowWindow = { [weak viewer] in
            guard let pid = viewer?.target?.pid else { return }
            // The helper owns Accessibility. This explicit user action brings the
            // app forward; it does not attempt to raise a particular window.
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        panel.canvas.onPermissions = { SettingsWindow.shared.show(.permissions) }
        panel.canvas.onKeyframe = { [weak self] in self?.client.keyframe(agent: agent.id) }
        placeNew(panel, agent: agent.id)
        update(viewer)
        client.start(); client.subscribe(.init(agent: agent.id, max_fps: 15, codec: .h264))
        panel.orderFrontRegardless()
    }
    func setStopped(_ stopped: Bool) {
        guard self.stopped != stopped else { return }
        self.stopped = stopped
        for viewer in viewers.values { update(viewer) }
        if !stopped { client.list() }
    }
    func updateHost(connectedIDs: Set<String>, stopped: Bool, noPermission: Bool) {
        setStopped(stopped)
        let regained = self.noPermission && !noPermission
        self.noPermission = noPermission
        for id in Array(viewers.keys) where !connectedIDs.contains(id) { viewers[id]?.panel.close() }
        for (id, viewer) in viewers {
            if regained, viewer.failure == .no_permission {
                viewer.failure = nil; client.subscribe(.init(agent: id, max_fps: 15))
            }
            update(viewer)
        }
    }
    func closeAll() { for viewer in Array(viewers.values) { viewer.panel.close() } }

    private func closed(_ agent: String) {
        viewers[agent] = nil; order.removeAll { $0 == agent }
        client.unsubscribe(agent: agent)
        if viewers.isEmpty { client.stop() }
    }
    private func update(_ viewer: Viewer) {
        if stopped { viewer.panel.canvas.state = .stopped; return }
        let failure = viewer.failure
        let state = PiPState(target: viewer.target?.state, end: viewer.end,
                             stopped: stopped || failure == .paused,
                             noPermission: noPermission || failure == .no_permission)
        if failure == .codec_unsupported || failure == .unauthorized || failure == .unsupported_version {
            viewer.panel.canvas.state = .unavailable
        } else { viewer.panel.canvas.state = state }
    }
    private func receive(_ event: StreamClientEvent) {
        switch event {
        case .connected:
            for viewer in viewers.values { viewer.panel.canvas.resetVideo() }
        case .disconnected:
            for viewer in viewers.values { viewer.end = .stopped; update(viewer) }
        case .failure:
            for viewer in viewers.values { viewer.end = .stopped; update(viewer) }
        case .message(let message):
            switch message {
            case .video(let sample): viewers[sample.header.agent]?.panel.canvas.enqueue(sample)
            case .control(.target(let target)):
                guard let viewer = viewers[target.agent] else { return }
                let changed = viewer.target?.window_id != target.window_id || viewer.target?.pid != target.pid
                viewer.target = target; viewer.end = nil; viewer.failure = nil
                viewer.panel.canvas.setTarget(target, changed: changed)
                viewer.panel.updateSize(CGSize(width: target.frame.width, height: target.frame.height))
                if !viewer.receivedTarget && viewer.followsStack { placeNew(viewer.panel, agent: target.agent) }
                viewer.receivedTarget = true
                update(viewer)
                restack()
            case .control(.cursor(let cursor)): viewers[cursor.agent]?.panel.canvas.setCursor(cursor)
            case .control(.agents(let list)):
                for agent in list.agents {
                    guard let viewer = viewers[agent.agent] else { continue }
                    viewer.panel.canvas.setIdentity(name: agent.name, slot: agent.color_slot)
                }
            case .control(.end(let end)):
                guard let viewer = viewers[end.agent] else { return }
                if end.reason == .disconnected { viewer.panel.close(); return }
                viewer.end = end.reason
                viewer.panel.canvas.clearTarget(); viewer.target = nil
                update(viewer)
            case .control(.error(let failure)):
                for (id, viewer) in viewers where failure.agent == nil || failure.agent == id {
                    viewer.failure = failure.code
                    if failure.code == .unknown_agent { viewer.end = .released }
                    update(viewer)
                }
            default: break
            }
        }
    }

    private var menuScreen: NSScreen? {
        guard let frame = statusItemFrame else { return NSScreen.screens.first }
        return NSScreen.screens.first { $0.frame.intersects(frame) }
    }
    private func initialOrigin(size: CGSize) -> CGPoint {
        if let saved = defaults.string(forKey: "agentPiPPosition") {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGRect(origin: point, size: size)) }) { return point }
        }
        let visible = menuScreen?.visibleFrame ?? .zero
        return CGPoint(x: min(statusItemFrame?.maxX ?? visible.maxX, visible.maxX) - size.width,
                       y: visible.maxY - size.height)
    }
    private func placeNew(_ panel: PiPWindow, agent: String) {
        var origin = initialOrigin(size: panel.frame.size)
        if let index = order.firstIndex(of: agent), index > 0, let previous = viewers[order[index - 1]]?.panel {
            origin = CGPoint(x: previous.frame.minX, y: previous.frame.minY - panel.frame.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
    private func restack() {
        // Panels dragged or resized by the user keep their own placement.
        // Untouched panels keep the specified eight-point gap as targets resize.
        for index in 1..<max(1, order.count) {
            guard let previous = viewers[order[index - 1]]?.panel,
                  let viewer = viewers[order[index]], viewer.followsStack else { continue }
            let panel = viewer.panel
            panel.setFrameOrigin(CGPoint(x: previous.frame.minX, y: previous.frame.minY - panel.frame.height - 8))
        }
    }
    private func placeAfterDrag(_ panel: PiPWindow) {
        guard let screen = panel.screen else { return }
        let visible = screen.visibleFrame, frame = panel.frame
        let corners = [CGPoint(x: visible.minX, y: visible.maxY - frame.height),
                       CGPoint(x: visible.maxX - frame.width, y: visible.maxY - frame.height),
                       CGPoint(x: visible.minX, y: visible.minY),
                       CGPoint(x: visible.maxX - frame.width, y: visible.minY)]
        if let nearest = corners.min(by: { hypot($0.x - frame.minX, $0.y - frame.minY) < hypot($1.x - frame.minX, $1.y - frame.minY) }),
           hypot(nearest.x - frame.minX, nearest.y - frame.minY) <= 32 {
            panel.setFrameOrigin(nearest)
        }
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: "agentPiPPosition")
    }
}

/// Reads the actual status-item location without creating another menu-bar item.
struct PiPStatusItemAnchor: NSViewRepresentable {
    let changed: (CGRect) -> Void
    func makeNSView(context: Context) -> AnchorView { let view = AnchorView(); view.changed = changed; return view }
    func updateNSView(_ view: AnchorView, context: Context) { view.changed = changed; view.report() }
    final class AnchorView: NSView {
        var changed: ((CGRect) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        func report() { if let window { changed?(window.convertToScreen(convert(bounds, to: nil))) } }
    }
}
