import CoreGraphics
import Darwin
import Foundation
import OCUStream

struct StreamWindowInfo: Equatable {
    var frame: StreamRect
    var scale: Double = 1
    var state: StreamTargetState = .live
}

/// Read-only window lookup. No window titles or other application content are retained.
protocol StreamWindowProvider {
    func window(id: UInt32, pid: Int32) -> StreamWindowInfo?
}
struct SystemStreamWindowProvider: StreamWindowProvider {
    func window(id: UInt32, pid: Int32) -> StreamWindowInfo? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
              }), let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        // Off-screen does not imply minimized: windows on other Spaces may stream.
        // Capture's later state callbacks supply minimized/hidden/no_permission.
        return StreamWindowInfo(frame: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }
}

struct StreamAgentSnapshot: Equatable {
    var paused: Bool
    var agents: [StreamAgent]
    var targets: [String: StreamTarget]
    var cursors: [String: StreamCursor]
}

/// Owned by the stream server queue. Files are read again only after their stat changes.
final class StreamAgents {
    private struct Target: Decodable {
        var client: String, name: String
        var slot: Int, busy: Bool
        var pid: Int32
        var app_name: String?, bundle_id: String?
        var window_ids: [UInt32]
        var main_window_id: UInt32
        var at: Double
    }
    private struct Cursor: Decodable {
        var client: String
        var pid: Int32, window_id: UInt32
        var x: Double, y: Double, to_x: Double?, to_y: Double?
        var kind: String, busy: Bool?, at: Double
    }
    /// The host's live state (`status.json`); `control-state.json` exists only after a first Pause.
    private struct Control: Decodable { var paused: Bool }
    private struct Stamp: Equatable {
        var inode: ino_t, size: off_t, seconds: Int, nanos: Int
    }
    private struct FileValue<T: Decodable> {
        var stamp: Stamp?
        var value: T?
        mutating func read(_ url: URL) -> T? {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else {
                stamp = nil; value = nil; return nil
            }
            let next = Stamp(inode: st.st_ino, size: st.st_size, seconds: st.st_mtimespec.tv_sec, nanos: st.st_mtimespec.tv_nsec)
            if next != stamp {
                stamp = next
                value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            }
            return value
        }
    }
    let runtime: URL
    private let windows: StreamWindowProvider
    private var targetFile = FileValue<[Target]>()
    private var cursorFile = FileValue<[Cursor]>()
    private var controlFile = FileValue<Control>()

    init(commandDirectory: URL, windows: StreamWindowProvider = SystemStreamWindowProvider()) {
        runtime = commandDirectory.deletingLastPathComponent(); self.windows = windows
    }
    func read() -> StreamAgentSnapshot {
        let paused = controlFile.read(runtime.appendingPathComponent("status.json"))?.paused ?? true
        let targets = targetFile.read(runtime.appendingPathComponent("targets.json")) ?? []
        let cursors = cursorFile.read(runtime.appendingPathComponent("cursors.json")) ?? []
        var result = StreamAgentSnapshot(paused: paused, agents: [], targets: [:], cursors: [:])
        guard !paused else { return result }
        for entry in targets {
            guard entry.window_ids.contains(entry.main_window_id), result.targets[entry.client] == nil else { continue }
            let info = windows.window(id: entry.main_window_id, pid: entry.pid) ??
                StreamWindowInfo(frame: .init(x: 0, y: 0, width: 0, height: 0), state: .closed)
            let target = StreamTarget(agent: entry.client, pid: entry.pid, app_name: entry.app_name,
                                      window_id: entry.main_window_id, frame: info.frame, scale: info.scale, state: info.state)
            result.targets[entry.client] = target
            result.agents.append(.init(agent: entry.client, name: entry.name, color_slot: entry.slot,
                                       app_name: entry.app_name, busy: entry.busy, state: target.state))
            if let cursor = cursors.first(where: { $0.client == entry.client && $0.pid == entry.pid && $0.window_id == entry.main_window_id }) {
                let point = StreamPoints.windowPoint(global: .init(x: cursor.x, y: cursor.y), frame: info.frame)
                let end = cursor.to_x.flatMap { x in cursor.to_y.map { y in
                    StreamPoints.windowPoint(global: .init(x: x, y: y), frame: info.frame)
                }}
                result.cursors[entry.client] = .init(agent: entry.client, x: point.x, y: point.y,
                    to_x: end.map { Double($0.x) }, to_y: end.map { Double($0.y) }, kind: cursor.kind, busy: cursor.busy ?? entry.busy, at: cursor.at)
            }
        }
        result.agents.sort { $0.agent < $1.agent }
        return result
    }
}
