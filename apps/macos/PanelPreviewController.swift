import AppKit
import SwiftUI
import OCUStream
import os

@MainActor
final class PanelPreviewController {
    private let runtime: URL
    private let agentsChanged: ([StreamAgent]) -> Void
    private var previews: [String: AgentPreview] = [:]
    private var agents: [Agent] = []
    private var stopped = false
    private var noPermission = false
    private var isOpen = false
    private lazy var client = StreamClient(runtime: runtime, callbackQueue: .main) { [weak self] event in
        MainActor.assumeIsolated { self?.receive(event) }
    }
    private lazy var subscriptions = PanelSubscriptions(
        subscribe: { [weak self] in self?.client.subscribe($0) },
        unsubscribe: { [weak self] in self?.client.unsubscribe(agent: $0) })

    init(runtime: URL, agentsChanged: @escaping ([StreamAgent]) -> Void = { _ in }) {
        self.runtime = runtime; self.agentsChanged = agentsChanged
    }
    // Keep list updates for Settings' watcher labels, even while the panel is
    // closed. No video subscription exists until the panel is visible.
    func start() { client.start() }
    func preview(for agent: Agent) -> AgentPreview {
        if let preview = previews[agent.id] { return preview }
        let preview = AgentPreview()
        preview.canvas.setIdentity(name: agent.name, slot: agent.slot ?? 0)
        preview.canvas.onPermissions = { SettingsWindow.shared.show(.permissions) }
        preview.canvas.onKeyframe = { [weak self] in
            guard let self, self.subscriptions.active.contains(agent.id) else { return }
            self.client.keyframe(agent: agent.id)
        }
        previews[agent.id] = preview
        update(preview)
        return preview
    }
    private static let log = Logger(subsystem: "com.andrewslabmd.opencomputeruse", category: "panel-preview")
    func setPanelOpen(_ open: Bool) {
        guard isOpen != open else { return }
        isOpen = open
        Self.log.info("panel \(open ? "open" : "closed", privacy: .public)")
        reconcile()
        if open { client.start(); client.list() }
        else { for preview in previews.values { preview.canvas.shutdown() } }
    }
    func setStopped(_ value: Bool) {
        let resumed = stopped && !value
        stopped = value
        for preview in previews.values { update(preview) }
        if resumed { client.list() }
    }
    func updateHost(agents: [Agent], stopped: Bool, noPermission: Bool) {
        self.agents = agents
        let regained = self.noPermission && !noPermission
        self.noPermission = noPermission
        setStopped(stopped)
        reconcile()
        for agent in agents {
            guard let preview = previews[agent.id] else { continue }
            preview.canvas.setIdentity(name: agent.name, slot: agent.slot ?? 0)
            if regained, preview.failure == .no_permission, subscriptions.active.contains(agent.id) {
                preview.failure = nil; client.subscribe(.init(agent: agent.id, max_fps: 15, codec: .h264))
            }
            update(preview)
        }
    }
    private func reconcile() {
        let ids = Set(agents.filter { $0.app != nil }.map(\.id))
        // A fast local peer can deliver the first target before SwiftUI builds
        // a joining row. Install render state before sending its subscription.
        if isOpen {
            for agent in agents where agent.app != nil { _ = preview(for: agent) }
        }
        let before = subscriptions.active.count
        subscriptions.update(isOpen: isOpen, agents: ids)
        if subscriptions.active.count != before {
            Self.log.info("preview subscriptions \(before, privacy: .public) -> \(self.subscriptions.active.count, privacy: .public)")
        }
        for id in Array(previews.keys) where !ids.contains(id) {
            previews.removeValue(forKey: id)?.canvas.shutdown()
        }
    }
    private func update(_ preview: AgentPreview) {
        let failure = preview.failure
        if stopped { preview.canvas.state = .stopped }
        else if failure == .codec_unsupported || failure == .unauthorized || failure == .unsupported_version {
            preview.canvas.state = .unavailable
        } else {
            preview.canvas.state = PiPState(target: preview.target?.state, end: preview.end,
                stopped: failure == .paused, noPermission: noPermission || failure == .no_permission)
        }
    }
    private func receive(_ event: StreamClientEvent) {
        switch event {
        case .connected:
            for preview in previews.values { preview.canvas.resetVideo() }
        case .disconnected, .failure:
            agentsChanged([])
            for preview in previews.values { preview.end = .stopped; update(preview) }
        case .message(let message):
            switch message {
            case .control(.agents(let list)): agentsChanged(list.agents)
            default:
                // Drop queued frames/controls after close or row removal.
                guard isOpen else { return }
                switch message {
                case .video(let sample): previews[sample.header.agent]?.canvas.enqueue(sample)
                case .control(.target(let target)):
                    guard let preview = previews[target.agent], subscriptions.active.contains(target.agent) else { return }
                    let changed = preview.target?.window_id != target.window_id || preview.target?.pid != target.pid
                    preview.target = target; preview.end = nil; preview.failure = nil
                    preview.canvas.setTarget(target, changed: changed)
                    preview.windowSize = CGSize(width: target.frame.width, height: target.frame.height)
                    update(preview)
                case .control(.cursor(let cursor)): previews[cursor.agent]?.canvas.setCursor(cursor)
                case .control(.end(let end)):
                    guard let preview = previews[end.agent] else { return }
                    preview.end = end.reason
                    preview.canvas.clearTarget(); preview.target = nil
                    update(preview)
                case .control(.error(let failure)):
                    for (id, preview) in previews where failure.agent == nil || failure.agent == id {
                        preview.failure = failure.code
                        if failure.code == .unknown_agent { preview.end = .released }
                        update(preview)
                    }
                default: break
                }
            }
        }
    }
}

/// MenuBarExtra retains its content between presentations. Observe actual
/// window ordering rather than relying on SwiftUI's view lifetime: every signal
/// (moved to a window, occlusion change, close, dismantle) re-reads whether the
/// panel window is really on screen, and checks once more a moment later. A
/// signal alone once said "closed" while the panel was showing (the first
/// opening after launch), which ended its previews with the panel open.
struct PanelVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Observer { let view = Observer(); view.changed = changed; return view }
    func updateNSView(_ view: Observer, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.report(); view.observe(nil) }
    final class Observer: NSView {
        var changed: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private weak var observed: NSWindow?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe(window) }
        static func showing(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
        }
        func report() {
            changed?(Self.showing(observed))
            // Settle after the menu's open or close animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.changed?(Self.showing(self.observed))
            }
        }
        func observe(_ window: NSWindow?) {
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            observed = window
            report()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
