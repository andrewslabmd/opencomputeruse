import Darwin
import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

struct StreamTestWindows: StreamWindowProvider {
    var frame = StreamRect(x: 100, y: 200, width: 800, height: 400)
    func window(id: UInt32, pid: Int32) -> StreamWindowInfo? { .init(frame: frame) }
}
final class StreamTestSource: StreamFrameSource, LiveFrameSource {
    let liveFrames = LiveFrameBuffer()
    private let lock = NSLock()
    private var callback: ((StreamFrameEvent) -> Void)?
    private var wanted = false
    private var requests = 0
    private var configurations: [StreamFrameConfiguration] = []
    private var stops = 0
    private var window: UInt32?
    var keyframeRequests: Int { lock.withLock { requests } }
    var stopCount: Int { lock.withLock { stops } }
    var configs: [StreamFrameConfiguration] { lock.withLock { configurations } }
    var windowID: UInt32? { lock.withLock { window } }
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, receive: @escaping (StreamFrameEvent) -> Void) throws {
        lock.withLock { window = windowID; configurations.append(configuration); callback = receive }
    }
    func configure(_ configuration: StreamFrameConfiguration) { lock.withLock { configurations.append(configuration) } }
    func requestKeyframe() { lock.withLock { wanted = true; requests += 1 } }
    func stop() { liveFrames.stop(); lock.withLock { stops += 1; callback = nil } }
    func emit(pts: Double, size: Int = 7, keyframe: Bool? = nil, codec: StreamCodec = .h264) {
        let (receive, key): (((StreamFrameEvent) -> Void)?, Bool) = lock.withLock {
            let key = keyframe ?? wanted
            if key { wanted = false }
            return (callback, key)
        }
        var data = Data([0,0,0,3,0x65,1,2])
        if size > data.count { data.append(Data(repeating: 1, count: size - data.count)) }
        receive?(.sample(.init(pts: pts, keyframe: key,
            format: key ? .init(sps: [Data([0x67])], pps: [Data([0x68])]) : nil, data: data, codec: codec)))
    }
    func event(_ event: StreamFrameEvent) { let receive = lock.withLock { callback }; receive?(event) }
}
final class StreamTestFactory: StreamFrameSourceFactory {
    private let lock = NSLock()
    private var created: [StreamTestSource] = []
    var sources: [StreamTestSource] { lock.withLock { created } }
    var hevcSupported = false
    func supports(_ codec: StreamCodec) -> Bool { codec == .h264 || hevcSupported }
    func makeSource() -> StreamFrameSource {
        let source = StreamTestSource(); lock.withLock { created.append(source) }; return source
    }
}
struct StreamTestTimeout: Error {}
final class StreamTestPeer {
    let fd: Int32
    private var isClosed = false
    private var decoder = StreamDecoder()
    private var buffered: [StreamMessage] = []
    init(path: String, receiveBuffer: Int32? = nil) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamServerError.system(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        if var size = receiveBuffer { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) }
        do {
            var address = try StreamServer.address(path)
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }}
            guard result == 0 else { throw StreamServerError.system(errno) }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw StreamServerError.system(errno) }
        } catch { Darwin.close(fd); throw error }
    }
    deinit { close() }
    func close() { if !isClosed { isClosed = true; Darwin.close(fd) } }
    func send(_ control: StreamControl) throws { try sendRaw(StreamFraming.encode(.control(control))) }
    func sendRaw(_ data: Data) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(3)
        while offset < data.count {
            guard Date() < deadline else { throw StreamTestTimeout() }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 100) >= 0 else { throw StreamServerError.system(errno) }
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if errno != EAGAIN && errno != EINTR { throw StreamServerError.system(errno) }
        }
    }
    func next(timeout: TimeInterval = 3) throws -> StreamMessage? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        let deadline = Date().addingTimeInterval(timeout)
        var data = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 10)
            if ready < 0 && errno != EINTR { throw StreamServerError.system(errno) }
            if ready <= 0 { continue }
            let count = Darwin.read(fd, &data, data.count)
            if count == 0 || (count < 0 && errno == ECONNRESET) { return nil }
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { throw StreamServerError.system(errno) }
                continue
            }
            buffered += try decoder.append(Data(data.prefix(count)))
            if !buffered.isEmpty { return buffered.removeFirst() }
        }
        throw StreamTestTimeout()
    }
    func hello(token: String = StreamTestFixture.token, version: Int = 1, client: String = "Test viewer") throws {
        try send(.hello(.init(version: version, token: token, client: client)))
    }
    func authenticate(client: String = "Test viewer") throws {
        try hello(client: client)
        XCTAssertEqual(try next(), .control(.hello(.init())))
    }
    func subscribe(agent: String = "a", fps: Int = 15) throws {
        try send(.subscribe(.init(agent: agent, max_fps: fps)))
        guard case .control(.target(let target)) = try next() else { XCTFail("Expected target"); return }
        XCTAssertEqual(target.agent, agent)
        guard case .control(.cursor(let cursor)) = try next() else { XCTFail("Expected cursor"); return }
        XCTAssertEqual(cursor.agent, agent)
    }
}
final class StreamTestFixture {
    // Synthetic fixture credential. Never read or alter the installation runtime.
    static let token = String(repeating: "a", count: 64)
    let runtime: URL
    var commands: URL { runtime.appendingPathComponent("commands") }
    let factory = StreamTestFactory()
    var server: StreamServer!
    init(timeout: TimeInterval = StreamServer.helloTimeout, permission: Bool = true) throws {
        runtime = URL(fileURLWithPath: "/tmp/ocu-stream-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Self.token.write(to: runtime.appendingPathComponent("host-token"), atomically: true, encoding: .utf8)
        chmod(runtime.appendingPathComponent("host-token").path, 0o600)
        try write("status.json", #"{"paused":false}"#)
        try targets()
        try cursors()
        server = StreamServer(commandDirectory: commands, factory: factory, windows: StreamTestWindows(), permission: { permission }, helloTimeout: timeout)
    }
    deinit { server?.stop(); try? FileManager.default.removeItem(at: runtime) }
    func write(_ file: String, _ text: String) throws {
        try Data(text.utf8).write(to: runtime.appendingPathComponent(file), options: .atomic)
    }
    func targets(name: String = "Agent", window: UInt32 = 42, busy: Bool = true) throws {
        try write("targets.json", """
        [{"client":"a","name":"\(name)","slot":2,"busy":\(busy),"pid":123,"app_name":"Fixture","bundle_id":"test.fixture","window_ids":[\(window)],"main_window_id":\(window),"at":123,"window_title":"Secret title"}]
        """)
    }
    func cursors(window: UInt32 = 42) throws {
        try write("cursors.json", """
        [{"client":"a","name":"Agent","slot":2,"busy":true,"pid":123,"window_id":\(window),"x":125,"y":250,"to_x":150,"to_y":275,"kind":"drag","at":123}]
        """)
    }
    func peer(receiveBuffer: Int32? = nil) throws -> StreamTestPeer {
        try StreamTestPeer(path: server.socketPath, receiveBuffer: receiveBuffer)
    }
}

func streamEventually(timeout: TimeInterval = 3, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertTrue(predicate(), file: file, line: line)
}
