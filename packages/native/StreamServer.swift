import CoreGraphics
import Darwin
import Foundation
import OCUStream

struct StreamEncodedSample {
    var pts: Double
    var keyframe: Bool
    var format: StreamVideoFormat?
    var data: Data // AVCC, never Annex B
}
enum StreamFrameEvent {
    case sample(StreamEncodedSample)
    case state(StreamTargetState)
    case ended(StreamEndReason)
}
struct StreamFrameConfiguration: Equatable {
    var maxFPS: Int
    var maxLongEdge: Int?
    var codec: StreamCodec
}
enum StreamSourceError: Error { case noPermission, codecUnsupported }

/// Implementations never run on the helper's native queue. Callbacks may arrive on
/// any queue; the server serializes them. Source methods must return without
/// waiting for the callback queue (callbacks may be waiting on the server queue).
/// stop() must arrange release of capture resources without waiting on a viewer.
protocol StreamFrameSource: AnyObject {
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, receive: @escaping (StreamFrameEvent) -> Void) throws
    func configure(_ configuration: StreamFrameConfiguration)
    func requestKeyframe()
    func stop()
}
protocol StreamFrameSourceFactory {
    func supports(_ codec: StreamCodec) -> Bool
    func makeSource() -> StreamFrameSource
}

enum StreamServerError: Error, Equatable {
    case unsafeDirectory, unsafeSocket, socketInUse, unsafeToken, invalidToken, pathTooLong
    case system(Int32)
}

/// Standalone, headless transport. start/stop may be called from any outside queue.
/// Socket IO, polling, subscriptions and source calls all use this private queue.
final class StreamServer {
    static let pollInterval: TimeInterval = 0.05
    static let helloTimeout: TimeInterval = 5
    static let controlQueueLimit = 256
    static let videoQueueLimit = 3
    static func allowsPeer(uid: uid_t, serverUID: uid_t = getuid()) -> Bool { uid == serverUID }
    static func acceptsSocket(mode: mode_t, uid: uid_t, serverUID: uid_t = getuid()) -> Bool {
        mode & S_IFMT == S_IFSOCK && uid == serverUID
    }
    private struct SessionKey: Hashable { var window: UInt32; var codec: StreamCodec }
    private final class Session {
        let id = UUID()
        let source: StreamFrameSource
        var configuration: StreamFrameConfiguration
        var state: StreamTargetState?
        init(source: StreamFrameSource, configuration: StreamFrameConfiguration) {
            self.source = source; self.configuration = configuration
        }
    }
    private final class Subscription {
        var request: StreamSubscription
        var key: SessionKey
        var waitingForKeyframe = true
        var draining = false
        init(request: StreamSubscription, key: SessionKey) { self.request = request; self.key = key }
    }
    private struct Pending {
        var data: Data
        var offset = 0
        var agent: String?
        var video: Bool
    }
    private final class Client {
        let fd: Int32
        let id = UUID()
        var decoder = StreamDecoder()
        var read: DispatchSourceRead?
        var write: DispatchSourceWrite?
        var writeActive = false
        var deadline: DispatchWorkItem?
        var authenticated = false
        var closing = false
        var name: String?
        var listed = false
        var lastAgents: [StreamAgent]?
        var subscriptions: [String: Subscription] = [:]
        var pending: [Pending] = []
        init(fd: Int32) { self.fd = fd }
    }
    private let queue = DispatchQueue(label: "OpenComputerUse.stream-server")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let agents: StreamAgents
    private let factory: StreamFrameSourceFactory
    private let permission: () -> Bool
    private let authenticationTimeout: TimeInterval
    private var token = ""
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var socketInode: ino_t?
    private var clients: [UUID: Client] = [:]
    private var sessions: [SessionKey: Session] = [:]
    private var snapshot = StreamAgentSnapshot(paused: true, agents: [], targets: [:], cursors: [:])
    var socketPath: String { agents.runtime.appendingPathComponent("stream.sock").path }

    init(commandDirectory: URL, factory: StreamFrameSourceFactory,
         windows: StreamWindowProvider = SystemStreamWindowProvider(),
         permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         helloTimeout: TimeInterval = StreamServer.helloTimeout) {
        agents = StreamAgents(commandDirectory: commandDirectory, windows: windows)
        self.factory = factory; self.permission = permission; authenticationTimeout = helloTimeout
        queue.setSpecific(key: queueKey, value: true)
    }
    func start() throws { try queue.sync { try startOnQueue() } }
    func stop() { queue.sync { stopOnQueue() } }
    deinit { stopOnQueue() }

    private func startOnQueue() throws {
        guard listener == -1 else { return }
        var st = stat()
        guard lstat(agents.runtime.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == getuid(), st.st_mode & 0o7777 == 0o700 else { throw StreamServerError.unsafeDirectory }
        let tokenPath = agents.runtime.appendingPathComponent("host-token").path
        guard lstat(tokenPath, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o7777 == 0o600 else { throw StreamServerError.unsafeToken }
        token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StreamServerError.invalidToken
        }
        var address = try Self.address(socketPath)
        if lstat(socketPath, &st) == 0 {
            guard Self.acceptsSocket(mode: st.st_mode, uid: st.st_uid) else { throw StreamServerError.unsafeSocket }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw StreamServerError.system(errno) }
            do { try Self.prepare(probe) } catch { Darwin.close(probe); throw error }
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let failure = errno; Darwin.close(probe)
            guard result != 0, failure != EINPROGRESS, failure != EAGAIN else { throw StreamServerError.socketInUse }
            guard failure == ECONNREFUSED else { throw StreamServerError.system(failure) }
            guard unlink(socketPath) == 0 else { throw StreamServerError.system(errno) }
        } else if errno != ENOENT { throw StreamServerError.system(errno) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamServerError.system(errno) }
        var bound = false
        do {
            try Self.prepare(fd)
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw StreamServerError.system(errno) }
            bound = true
            guard chmod(socketPath, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else { throw StreamServerError.system(errno) }
            guard lstat(socketPath, &st) == 0 else { throw StreamServerError.system(errno) }
            socketInode = st.st_ino; listener = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients() }
            source.setCancelHandler { Darwin.close(fd) }
            acceptSource = source; source.resume()
            snapshot = agents.read()
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            poll.setEventHandler { [weak self] in self?.refresh() }
            timer = poll; poll.resume()
        } catch {
            Darwin.close(fd)
            if bound { unlink(socketPath) }
            throw error
        }
    }
    private static func prepare(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw StreamServerError.system(errno) }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
            throw StreamServerError.system(errno)
        }
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw StreamServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    private func acceptClients() {
        while listener >= 0 {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, Self.allowsPeer(uid: uid) else { Darwin.close(fd); continue }
            do { try Self.prepare(fd) } catch { Darwin.close(fd); continue }
            let client = Client(fd: fd); clients[client.id] = client
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self, weak client] in if let client { self?.read(client) } }
            read.setCancelHandler { Darwin.close(fd) }
            client.read = read
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            write.setEventHandler { [weak self, weak client] in if let client { self?.flush(client) } }
            client.write = write
            let deadline = DispatchWorkItem { [weak self, weak client] in
                if let client, !client.authenticated { self?.disconnect(client) }
            }
            client.deadline = deadline
            queue.asyncAfter(deadline: .now() + authenticationTimeout, execute: deadline)
            read.resume()
        }
    }
    private func read(_ client: Client) {
        // IO chunk size only; the protocol limit is enforced by StreamDecoder.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Yield after each read so a flooding peer cannot starve Pause polling.
        let count = Darwin.read(client.fd, &buffer, buffer.count)
        if count == 0 { disconnect(client); return }
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { disconnect(client) }
            return
        }
        do {
            for message in try client.decoder.append(Data(buffer.prefix(count))) {
                guard clients[client.id] != nil, !client.closing else { break }
                guard case .control(let control) = message else { disconnect(client); break }
                receive(control, from: client)
            }
        } catch { disconnect(client) }
    }
    private func receive(_ control: StreamControl, from client: Client) {
        if !client.authenticated {
            guard case .hello(let hello) = control, let provided = hello.token, let name = hello.client else { disconnect(client); return }
            guard constantTimeEqual(provided, token) else { refuseAndClose(client, code: .unauthorized); return }
            guard hello.version == StreamFraming.version else { refuseAndClose(client, code: .unsupported_version); return }
            client.authenticated = true; client.name = name; client.deadline?.cancel(); client.deadline = nil
            send(.hello(.init()), to: client); return
        }
        refresh()
        switch control {
        case .list:
            client.listed = true; publishAgents(client, force: true)
        case .subscribe(let request): subscribe(request, client: client)
        case .unsubscribe(let request): end(request.agent, client: client, reason: .unsubscribed)
        case .keyframe(let request):
            if let sub = client.subscriptions[request.agent] { sessions[sub.key]?.source.requestKeyframe() }
        default: disconnect(client)
        }
    }
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
    private func refuseAndClose(_ client: Client, code: StreamErrorCode) {
        client.closing = true; client.deadline?.cancel()
        send(.error(.init(code: code, supported: code == .unsupported_version ? [1] : nil)), to: client)
        if client.pending.isEmpty { disconnect(client) }
    }
    private func subscribe(_ request: StreamSubscription, client: Client) {
        func refuse(_ code: StreamErrorCode) { send(.error(.init(code: code, agent: request.agent)), to: client) }
        guard !snapshot.paused else { refuse(.paused); return }
        guard let target = snapshot.targets[request.agent] else { refuse(.unknown_agent); return }
        guard permission(), target.state != .no_permission else { refuse(.no_permission); return }
        guard factory.supports(request.codec) else { refuse(.codec_unsupported); return }
        guard (1...30).contains(request.max_fps), request.max_long_edge.map({ $0 > 0 }) ?? true else { disconnect(client); return }
        if client.subscriptions[request.agent] != nil { end(request.agent, client: client, reason: .unsubscribed) }
        let key = SessionKey(window: target.window_id, codec: request.codec)
        let sub = Subscription(request: request, key: key)
        client.subscriptions[request.agent] = sub
        do { try ensureSession(key) } catch {
            client.subscriptions[request.agent] = nil
            if let error = error as? StreamSourceError {
                refuse(error == .noPermission ? .no_permission : .codec_unsupported)
            } else { send(.end(.init(agent: request.agent, reason: .error)), to: client) }
            return
        }
        send(.target(effectiveTarget(target, key: key)), to: client)
        if let cursor = snapshot.cursors[request.agent] { send(.cursor(cursor), to: client) }
        sessions[key]?.source.requestKeyframe()
    }
    private func configuration(for key: SessionKey) -> StreamFrameConfiguration {
        let requests = clients.values.flatMap { $0.subscriptions.values }.filter { $0.key == key }.map(\.request)
        return .init(maxFPS: requests.map(\.max_fps).max()!,
                     maxLongEdge: requests.contains(where: { $0.max_long_edge == nil }) ? nil : requests.compactMap(\.max_long_edge).max(), codec: key.codec)
    }
    private func ensureSession(_ key: SessionKey) throws {
        let config = configuration(for: key)
        if let session = sessions[key] {
            if session.configuration != config { session.configuration = config; session.source.configure(config) }
            return
        }
        let session = Session(source: factory.makeSource(), configuration: config)
        sessions[key] = session
        do {
            try session.source.start(windowID: key.window, configuration: config) { [weak self, weak session] event in
                guard let self, let session else { return }
                let deliver = { [weak self, weak session] in
                    guard let self, let session, self.sessions[key]?.id == session.id else { return }
                    self.frame(event, key: key)
                }
                // Backpressure ends at the server queue, never at a socket. This
                // prevents an unbounded dispatch backlog of encoded samples. Inline
                // callbacks during start/configure are deferred until controls queue.
                if DispatchQueue.getSpecific(key: self.queueKey) == true {
                    self.queue.async(execute: deliver)
                } else {
                    self.queue.sync(execute: deliver)
                }
            }
        } catch { sessions[key] = nil; session.source.stop(); throw error }
    }
    private func reconcileSessions() {
        let used = Set(clients.values.flatMap { $0.subscriptions.values.map(\.key) })
        for (key, session) in sessions where !used.contains(key) { sessions[key] = nil; session.source.stop() }
        for key in used {
            if let session = sessions[key] {
                let config = configuration(for: key)
                if session.configuration != config { session.configuration = config; session.source.configure(config) }
            }
        }
    }
    private func effectiveTarget(_ target: StreamTarget, key: SessionKey) -> StreamTarget {
        var result = target
        if let state = sessions[key]?.state { result.state = state }
        return result
    }
    private func refresh() {
        let previous = snapshot
        snapshot = agents.read()
        for client in Array(clients.values) where client.authenticated && !client.closing {
            for (agent, sub) in Array(client.subscriptions) {
                guard !snapshot.paused else { end(agent, client: client, reason: .paused); continue }
                guard let target = snapshot.targets[agent] else { end(agent, client: client, reason: .released); continue }
                if target.window_id != sub.key.window || target.pid != previous.targets[agent]?.pid {
                    discardVideo(agent, client: client)
                    sub.key = .init(window: target.window_id, codec: sub.request.codec)
                    sub.waitingForKeyframe = true; sub.draining = false
                    do { try ensureSession(sub.key) } catch { end(agent, client: client, reason: .error); continue }
                    send(.target(effectiveTarget(target, key: sub.key)), to: client)
                    if let cursor = snapshot.cursors[agent] { send(.cursor(cursor), to: client) }
                    sessions[sub.key]?.source.requestKeyframe()
                } else {
                    if previous.targets[agent] != target { send(.target(effectiveTarget(target, key: sub.key)), to: client) }
                    if previous.cursors[agent] != snapshot.cursors[agent], let cursor = snapshot.cursors[agent] { send(.cursor(cursor), to: client) }
                }
            }
            if client.listed { publishAgents(client) }
        }
        reconcileSessions()
    }
    private func publishAgents(_ client: Client, force: Bool = false) {
        let list = snapshot.agents.map { agent -> StreamAgent in
            var result = agent
            if let target = snapshot.targets[agent.agent],
               let state = sessions.first(where: { $0.key.window == target.window_id })?.value.state { result.state = state }
            return result
        }
        if force || client.lastAgents != list { client.lastAgents = list; send(.agents(.init(agents: list)), to: client) }
    }
    private func frame(_ event: StreamFrameEvent, key: SessionKey) {
        // Targets and Pause are applied by the 50 ms poll and on each control message.
        guard sessions[key] != nil else { return }
        switch event {
        case .sample(let sample):
            if let state = sessions[key]?.state, state != .live && state != .idle { return }
            for client in Array(clients.values) {
                for (agent, sub) in client.subscriptions where sub.key == key {
                    guard !sub.draining, !sub.waitingForKeyframe || sample.keyframe else { continue }
                    // Joining/resuming decoders require parameter sets with their IDR.
                    guard !sample.keyframe || sample.format != nil else { continue }
                    let count = client.pending.filter { $0.video && $0.agent == agent }.count
                    if count >= Self.videoQueueLimit {
                        sub.waitingForKeyframe = true; sub.draining = true
                        discardVideo(agent, client: client)
                        resumeDrained(client)
                        continue
                    }
                    sub.waitingForKeyframe = false
                    let video = StreamVideo(header: .init(agent: agent, pts: sample.pts, keyframe: sample.keyframe,
                        codec: key.codec, format: sample.keyframe ? sample.format : nil), data: sample.data)
                    enqueue(.video(video), client: client, agent: agent, video: true)
                }
            }
        case .state(let state):
            guard sessions[key]?.state != state else { return }
            sessions[key]?.state = state
            if state == .live { sessions[key]?.source.requestKeyframe() }
            for client in Array(clients.values) {
                for (agent, sub) in client.subscriptions where sub.key == key {
                    if state != .live && state != .idle { discardVideo(agent, client: client); sub.waitingForKeyframe = true }
                    if let target = snapshot.targets[agent] { send(.target(effectiveTarget(target, key: key)), to: client) }
                }
                if client.listed { publishAgents(client) }
            }
        case .ended(let reason):
            for client in Array(clients.values) {
                for (agent, sub) in Array(client.subscriptions) where sub.key == key { end(agent, client: client, reason: reason) }
            }
        }
    }
    private func end(_ agent: String, client: Client, reason: StreamEndReason) {
        guard client.subscriptions.removeValue(forKey: agent) != nil else { return }
        // A partially written frame must finish to preserve framing; everything
        // unsent for this subscription is withdrawn before its end message.
        client.pending.removeAll { $0.agent == agent && $0.offset == 0 }
        send(.end(.init(agent: agent, reason: reason)), to: client)
        reconcileSessions()
    }
    private func discardVideo(_ agent: String, client: Client) {
        client.pending.removeAll { $0.video && $0.agent == agent && $0.offset == 0 }
    }
    private func resumeDrained(_ client: Client) {
        for (agent, sub) in client.subscriptions where sub.draining {
            if !client.pending.contains(where: { $0.video && $0.agent == agent }) {
                sub.draining = false; sessions[sub.key]?.source.requestKeyframe()
            }
        }
    }
    private func send(_ control: StreamControl, to client: Client) {
        let agent: String?
        switch control { case .target(let t): agent = t.agent; case .cursor(let c): agent = c.agent; default: agent = nil }
        enqueue(.control(control), client: client, agent: agent, video: false)
    }
    private func enqueue(_ message: StreamMessage, client: Client, agent: String?, video: Bool) {
        guard clients[client.id] != nil else { return }
        do {
            let data = try StreamFraming.encode(message)
            client.pending.append(.init(data: data, agent: agent, video: video))
            if !video, client.pending.filter({ !$0.video }).count > Self.controlQueueLimit { disconnect(client); return }
            if !client.writeActive { client.writeActive = true; client.write?.resume() }
        } catch { disconnect(client) }
    }
    private func flush(_ client: Client) {
        guard clients[client.id] != nil else { return }
        // One nonblocking write per event preserves fairness between clients.
        if let first = client.pending.first {
            let count = first.data.withUnsafeBytes { bytes in
                Darwin.write(client.fd, bytes.baseAddress!.advanced(by: first.offset), first.data.count - first.offset)
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { disconnect(client) }
                return
            }
            client.pending[0].offset += count
            if client.pending[0].offset == client.pending[0].data.count { client.pending.removeFirst() }
        }
        resumeDrained(client)
        if client.pending.isEmpty {
            if client.closing { disconnect(client); return }
            if client.writeActive { client.writeActive = false; client.write?.suspend() }
        }
    }
    private func disconnect(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.deadline?.cancel(); client.deadline = nil
        client.subscriptions.removeAll(); client.pending.removeAll()
        if !client.writeActive { client.writeActive = true; client.write?.resume() }
        client.write?.cancel(); client.read?.cancel()
        client.write = nil; client.read = nil
        reconcileSessions()
    }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        for client in Array(clients.values) {
            for agent in Array(client.subscriptions.keys) { end(agent, client: client, reason: .stopped) }
            // Best-effort nonblocking delivery on shutdown; never wait on a peer.
            while !client.pending.isEmpty {
                let before = client.pending[0].offset
                let count = client.pending.count
                flush(client)
                if clients[client.id] == nil || (client.pending.count == count && client.pending.first?.offset == before) { break }
            }
            disconnect(client)
        }
        for session in sessions.values { session.source.stop() }; sessions.removeAll()
        acceptSource?.cancel(); acceptSource = nil; listener = -1
        var st = stat()
        if let inode = socketInode, lstat(socketPath, &st) == 0, st.st_ino == inode,
           Self.acceptsSocket(mode: st.st_mode, uid: st.st_uid) { unlink(socketPath) }
        socketInode = nil; token = ""
    }
}
