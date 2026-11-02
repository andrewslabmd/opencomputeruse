import Foundation
import Darwin

public enum StreamClientEvent {
    case connected
    case disconnected
    case message(StreamMessage)
    case failure(Error)
}
public enum StreamClientError: Error, Equatable {
    case pathTooLong, invalidHello, system(Int32)
}

/// A nonblocking protocol-v1 client. All IO and token reads use a private queue;
/// events are delivered in order on a serial queue targeting the caller's queue.
/// Desired subscriptions survive reconnect and release, until unsubscribe/stop.
public final class StreamClient {
    private final class Connection {
        let fd: Int32
        var read: DispatchSourceRead?
        var write: DispatchSourceWrite?
        var writeActive = false
        var connecting = true
        var authenticated = false
        var decoder = StreamDecoder()
        var pending: [Data] = []
        var offset = 0
        var active = Set<String>()
        init(_ fd: Int32) { self.fd = fd }
    }
    private let runtime: URL
    private let name: String
    private let queue = DispatchQueue(label: "OpenComputerUse.stream-client")
    private let delivery: DispatchQueue
    private let receive: (StreamClientEvent) -> Void
    private var running = false
    private var connection: Connection?
    private var retry: DispatchWorkItem?
    private var desired: [String: StreamSubscription] = [:]

    public init(runtime: URL, client: String = "Open Computer Use", callbackQueue: DispatchQueue,
                receive: @escaping (StreamClientEvent) -> Void) {
        self.runtime = runtime; name = client; self.receive = receive
        delivery = DispatchQueue(label: "OpenComputerUse.stream-events", target: callbackQueue)
    }
    public func start() { queue.async { [weak self] in
        guard let self, !self.running else { return }
        self.running = true; self.connect()
    } }
    public func stop() { queue.async { [weak self] in
        guard let self else { return }
        self.running = false; self.retry?.cancel(); self.retry = nil
        self.desired.removeAll(); self.disconnect()
    } }
    public func list() { queue.async { [weak self] in self?.sendIfReady(.list) } }
    public func subscribe(_ subscription: StreamSubscription) { queue.async { [weak self] in
        guard let self else { return }
        let changed = self.desired[subscription.agent] != subscription
        self.desired[subscription.agent] = subscription
        if let c = self.connection, c.authenticated, changed || !c.active.contains(subscription.agent) {
            c.active.insert(subscription.agent); self.send(.subscribe(subscription), on: c)
        }
    } }
    public func unsubscribe(agent: String) { queue.async { [weak self] in
        guard let self else { return }
        self.desired[agent] = nil
        self.connection?.active.remove(agent)
        self.sendIfReady(.unsubscribe(.init(agent: agent)))
    } }
    public func keyframe(agent: String) { queue.async { [weak self] in self?.sendIfReady(.keyframe(.init(agent: agent))) } }

    deinit {
        retry?.cancel()
        Self.close(connection)
    }
    private func emit(_ event: StreamClientEvent) { delivery.async { [receive] in receive(event) } }
    private func connect() {
        guard running, connection == nil else { return }
        do {
            let token = try String(contentsOf: runtime.appendingPathComponent("host-token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(runtime.appendingPathComponent("stream.sock").path.utf8) + [0]
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw StreamClientError.pathTooLong }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StreamClientError.system(errno) }
            let c = Connection(fd); connection = c
            var yes: Int32 = 1
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw StreamClientError.system(errno)
            }
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 || errno == EINPROGRESS || errno == EAGAIN else { throw StreamClientError.system(errno) }
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self, weak c] in if let c { self?.read(c) } }
            read.setCancelHandler { Darwin.close(fd) }
            c.read = read; read.resume()
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            write.setEventHandler { [weak self, weak c] in if let c { self?.flush(c) } }
            c.write = write
            send(.hello(.init(version: StreamFraming.version, token: token, client: name)), on: c)
        } catch { emit(.failure(error)); disconnect() }
    }
    private func sendIfReady(_ control: StreamControl) {
        if let c = connection, c.authenticated { send(control, on: c) }
    }
    private func send(_ control: StreamControl, on c: Connection) {
        guard connection === c else { return }
        do {
            c.pending.append(try StreamFraming.encode(.control(control)))
            if !c.writeActive { c.writeActive = true; c.write?.resume() }
        } catch { emit(.failure(error)); disconnect() }
    }
    private func flush(_ c: Connection) {
        guard connection === c else { return }
        if c.connecting {
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(c.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                emit(.failure(StreamClientError.system(error == 0 ? errno : error))); disconnect(); return
            }
            c.connecting = false
        }
        if let first = c.pending.first {
            let n = first.withUnsafeBytes { Darwin.write(c.fd, $0.baseAddress!.advanced(by: c.offset), first.count - c.offset) }
            if n < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { emit(.failure(StreamClientError.system(errno))); disconnect() }
                return
            }
            c.offset += n
            if c.offset == first.count { c.pending.removeFirst(); c.offset = 0 }
        }
        if c.pending.isEmpty, c.writeActive { c.writeActive = false; c.write?.suspend() }
    }
    private func read(_ c: Connection) {
        guard connection === c else { return }
        // Buffer granularity, not a protocol or frame-size limit.
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(c.fd, &bytes, bytes.count)
        if n == 0 { disconnect(); return }
        if n < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { emit(.failure(StreamClientError.system(errno))); disconnect() }
            return
        }
        do {
            for message in try c.decoder.append(Data(bytes.prefix(n))) {
                guard connection === c else { break }
                if !c.authenticated {
                    if case .control(.error) = message { emit(.message(message)); continue }
                    guard case .control(.hello(let hello)) = message, hello.version == StreamFraming.version else {
                        throw StreamClientError.invalidHello
                    }
                    c.authenticated = true; emit(.connected)
                    send(.list, on: c)
                    for sub in desired.values { c.active.insert(sub.agent); send(.subscribe(sub), on: c) }
                } else {
                    switch message {
                    case .control(.target(let target)): c.active.insert(target.agent)
                    case .control(.end(let end)):
                        c.active.remove(end.agent)
                        if end.reason == .capture_stopped_by_user || end.reason == .disconnected {
                            desired[end.agent] = nil
                        }
                    case .control(.error(let error)): if let agent = error.agent { c.active.remove(agent) }
                    case .control(.agents(let list)):
                        for agent in list.agents where !c.active.contains(agent.agent) {
                            if let sub = desired[agent.agent], agent.state != .stopped, agent.state != .no_permission {
                                c.active.insert(agent.agent); send(.subscribe(sub), on: c)
                            }
                        }
                    default: break
                    }
                }
                emit(.message(message))
            }
        } catch { emit(.failure(error)); disconnect() }
    }
    private static func close(_ c: Connection?) {
        guard let c else { return }
        if !c.writeActive { c.write?.resume() }
        c.write?.cancel()
        if let read = c.read { read.cancel() } else { Darwin.close(c.fd) }
    }
    private func disconnect() {
        let old = connection; connection = nil
        Self.close(old)
        if old != nil { emit(.disconnected) }
        guard running, retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.retry = nil; self?.connect() }
        retry = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
