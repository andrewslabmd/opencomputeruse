import XCTest
import Foundation
import Darwin
import OCUStream

/// A protocol peer only: no helper, screen capture, windows, or native actions.
private final class ClientTestServer {
    final class Peer {
        let fd: Int32
        var decoder = StreamDecoder()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
        func send(_ message: StreamMessage) {
            do {
                let bytes = try StreamFraming.encode(message)
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
                XCTAssertEqual(count, bytes.count)
            } catch { XCTFail("Encoding test message: \(error)") }
        }
    }
    let queue = DispatchQueue(label: "PiP.test-server")
    private let path: String
    private var listener: DispatchSourceRead?
    private var peers: [Peer] = []
    let receive: (StreamMessage, Peer) -> Void
    init(runtime: URL, receive: @escaping (StreamMessage, Peer) -> Void) throws {
        self.receive = receive; path = runtime.appendingPathComponent("stream.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamClientError.system(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw StreamClientError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else { Darwin.close(fd); throw StreamClientError.system(errno) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let accepted = accept(fd, nil, nil)
            guard accepted >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let peer = Peer(fd: accepted)
            let read = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: self.queue)
            read.setEventHandler { [weak self, weak peer] in
                guard let self, let peer else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(peer.fd, &buffer, buffer.count)
                guard count > 0 else { peer.source?.cancel(); return }
                do {
                    for message in try peer.decoder.append(Data(buffer.prefix(count))) { self.receive(message, peer) }
                } catch { XCTFail("Test server framing: \(error)") }
            }
            read.setCancelHandler { Darwin.close(accepted) }
            peer.source = read; self.peers.append(peer); read.resume()
        }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source; source.resume()
    }
    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for peer in peers { shutdown(peer.fd, SHUT_RDWR); peer.source?.cancel() }
            peers.removeAll(); unlink(path)
        }
    }
}

final class StreamClientTests: XCTestCase {
    private func runtime() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pip-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("test-only-token\n".utf8).write(to: url.appendingPathComponent("host-token"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var agent: StreamAgent { .init(agent: "workflow", name: "Agent", color_slot: 2, app_name: "Fixture", busy: true, state: .live) }
    private var target: StreamTarget {
        .init(agent: "workflow", pid: 1, app_name: "Fixture", window_id: 42,
              frame: .init(x: 100, y: 200, width: 800, height: 400), scale: 2, state: .live)
    }
    func testHelloListPushedAgentsSubscribeVideoCursorKeyframeUnsubscribeAndCallbackQueue() throws {
        let runtime = try runtime()
        let hello = expectation(description: "hello"), listed = expectation(description: "list")
        let subscribed = expectation(description: "subscribe"), keyframe = expectation(description: "keyframe")
        let gotTarget = expectation(description: "target"), gotCursor = expectation(description: "cursor")
        let gotVideo = expectation(description: "video"), pushed = expectation(description: "pushed agents")
        let ended = expectation(description: "unsubscribe end")
        let video = StreamVideo(header: .init(agent: "workflow", pts: 1.25, keyframe: true, codec: .h264,
            format: .init(sps: [Data([0x67])], pps: [Data([0x68])])), data: Data([0,0,0,1,0x65]))
        let agent = self.agent, target = self.target
        let server = try ClientTestServer(runtime: runtime) { message, peer in
            switch message {
            case .control(.hello(let request)):
                XCTAssertEqual(request.version, 1); XCTAssertEqual(request.token, "test-only-token"); XCTAssertEqual(request.client, "PiP test")
                hello.fulfill(); peer.send(.control(.hello(.init())))
            case .control(.list): listed.fulfill(); peer.send(.control(.agents(.init(agents: [agent]))))
            case .control(.subscribe(let request)):
                XCTAssertEqual(request, .init(agent: "workflow", max_fps: 15)); subscribed.fulfill()
                peer.send(.control(.target(target)))
                peer.send(.control(.cursor(.init(agent: "workflow", x: 20, y: 30, kind: "type", busy: true, at: 1))))
                peer.send(.video(video))
            case .control(.keyframe(let request)):
                XCTAssertEqual(request.agent, "workflow"); keyframe.fulfill()
                var next = agent; next.name = "Updated"
                peer.send(.control(.agents(.init(agents: [next]))))
            case .control(.unsubscribe(let request)): peer.send(.control(.end(.init(agent: request.agent, reason: .unsubscribed))))
            default: XCTFail("Unexpected request \(message)")
            }
        }
        defer { server.stop() }
        let callback = DispatchQueue(label: "PiP.test-callback")
        let specific = DispatchSpecificKey<Bool>(); callback.setSpecific(key: specific, value: true)
        let client = StreamClient(runtime: runtime, client: "PiP test", callbackQueue: callback) { event in
            XCTAssertEqual(DispatchQueue.getSpecific(key: specific), true)
            switch event {
            case .message(.control(.target(let value))): XCTAssertEqual(value, target); gotTarget.fulfill()
            case .message(.control(.cursor(let value))): XCTAssertEqual(value.kind, "type"); gotCursor.fulfill()
            case .message(.video(let value)): XCTAssertEqual(value, video); gotVideo.fulfill()
            case .message(.control(.agents(let list))): if list.agents.first?.name == "Updated" { pushed.fulfill() }
            case .message(.control(.end(let end))): XCTAssertEqual(end.reason, .unsubscribed); ended.fulfill()
            case .failure(let error): XCTFail("Client error \(error)")
            default: break
            }
        }
        defer { client.stop() }
        client.subscribe(.init(agent: "workflow")); client.start()
        wait(for: [hello, listed, subscribed, gotTarget, gotCursor, gotVideo], timeout: 4)
        client.keyframe(agent: "workflow")
        wait(for: [keyframe, pushed], timeout: 4)
        client.unsubscribe(agent: "workflow")
        wait(for: [ended], timeout: 4)
    }
    func testReconnectRereadsTokenAndResubscribesAfterServerRestarts() throws {
        let runtime = try runtime()
        let first = expectation(description: "first subscription"), second = expectation(description: "second subscription")
        let agent = self.agent
        let server = try ClientTestServer(runtime: runtime) { message, peer in
            switch message {
            case .control(.hello): peer.send(.control(.hello(.init())))
            case .control(.list): peer.send(.control(.agents(.init(agents: [agent]))))
            case .control(.subscribe): first.fulfill()
            default: break
            }
        }
        let callback = DispatchQueue(label: "PiP.reconnect-events")
        let client = StreamClient(runtime: runtime, callbackQueue: callback) { _ in }
        defer { client.stop() }
        client.start(); client.subscribe(.init(agent: "workflow"))
        wait(for: [first], timeout: 4)
        server.stop()
        try Data("restarted-test-token".utf8).write(to: runtime.appendingPathComponent("host-token"))
        let restarted = try ClientTestServer(runtime: runtime) { message, peer in
            switch message {
            case .control(.hello(let hello)):
                XCTAssertEqual(hello.token, "restarted-test-token"); peer.send(.control(.hello(.init())))
            case .control(.list): peer.send(.control(.agents(.init(agents: [agent]))))
            case .control(.subscribe(let sub)): XCTAssertEqual(sub.agent, "workflow"); second.fulfill()
            default: break
            }
        }
        defer { restarted.stop() }
        wait(for: [second], timeout: 5)
    }
    func testWrongTokenIsDeliveredAsProtocolError() throws {
        let runtime = try runtime(), unauthorized = expectation(description: "unauthorized")
        let server = try ClientTestServer(runtime: runtime) { message, peer in
            guard case .control(.hello) = message else { XCTFail("Hello must be first"); return }
            peer.send(.control(.error(.init(code: .unauthorized))))
            shutdown(peer.fd, SHUT_WR)
        }
        defer { server.stop() }
        let client = StreamClient(runtime: runtime, callbackQueue: .main) { event in
            if case .message(.control(.error(let error))) = event { XCTAssertEqual(error.code, .unauthorized); unauthorized.fulfill() }
        }
        defer { client.stop() }
        client.start()
        wait(for: [unauthorized], timeout: 4)
    }
    func testReleaseKeepsWatchIntentAndResubscribesOnPushedTarget() throws {
        let runtime = try runtime(), released = expectation(description: "released"), returned = expectation(description: "target returned")
        let agent = self.agent
        var count = 0
        let server = try ClientTestServer(runtime: runtime) { message, peer in
            switch message {
            case .control(.hello): peer.send(.control(.hello(.init())))
            case .control(.list): peer.send(.control(.agents(.init(agents: [agent]))))
            case .control(.subscribe):
                count += 1
                if count == 1 {
                    peer.send(.control(.end(.init(agent: "workflow", reason: .released))))
                    peer.send(.control(.agents(.init(agents: []))))
                    peer.send(.control(.agents(.init(agents: [agent]))))
                } else { returned.fulfill() }
            default: break
            }
        }
        defer { server.stop() }
        let client = StreamClient(runtime: runtime, callbackQueue: .main) { event in
            if case .message(.control(.end(let end))) = event { XCTAssertEqual(end.reason, .released); released.fulfill() }
        }
        defer { client.stop() }
        client.subscribe(.init(agent: "workflow")); client.start()
        wait(for: [released, returned], timeout: 4)
    }
    func testUserStoppedCaptureDoesNotRestartOnAgentUpdates() throws {
        let runtime = try runtime()
        let stopped = expectation(description: "user stopped capture")
        let updated = expectation(description: "updated agent")
        let barrier = expectation(description: "processed updates")
        var agent = self.agent
        agent.name = "Updated"
        let next = agent
        var subscriptions = 0
        let server = try ClientTestServer(runtime: runtime) { message, peer in
            switch message {
            case .control(.hello): peer.send(.control(.hello(.init())))
            case .control(.subscribe):
                subscriptions += 1
                XCTAssertEqual(subscriptions, 1, "User-stopped capture must wait for a new Watch")
                if subscriptions == 1 {
                    peer.send(.control(.end(.init(agent: "workflow", reason: .capture_stopped_by_user))))
                    peer.send(.control(.agents(.init(agents: [next]))))
                }
            case .control(.keyframe): barrier.fulfill()
            default: break
            }
        }
        defer { server.stop() }
        let client = StreamClient(runtime: runtime, callbackQueue: .main) { event in
            switch event {
            case .message(.control(.end(let end))):
                XCTAssertEqual(end.reason, .capture_stopped_by_user); stopped.fulfill()
            case .message(.control(.agents)): updated.fulfill()
            default: break
            }
        }
        defer { client.stop() }
        client.subscribe(.init(agent: "workflow")); client.start()
        wait(for: [stopped, updated], timeout: 4)
        client.keyframe(agent: "workflow")
        wait(for: [barrier], timeout: 4)
    }

}
