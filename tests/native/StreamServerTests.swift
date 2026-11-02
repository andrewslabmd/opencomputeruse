import Darwin
import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

final class StreamServerTests: XCTestCase {
    func testHelloAuthVersionTimeoutAndFirstMessage() throws {
        let fixture = try StreamTestFixture(timeout: 0.1); try fixture.server.start()
        let good = try fixture.peer(); try good.authenticate()
        let bad = try fixture.peer(); try bad.hello(token: String(repeating: "b", count: 64))
        XCTAssertEqual(try bad.next(), .control(.error(.init(code: .unauthorized))))
        XCTAssertNil(try bad.next())
        let version = try fixture.peer(); try version.hello(version: 2)
        XCTAssertEqual(try version.next(), .control(.error(.init(code: .unsupported_version, supported: [1]))))
        XCTAssertNil(try version.next())
        let early = try fixture.peer(); try early.send(.list); XCTAssertNil(try early.next())
        let idle = try fixture.peer(); XCTAssertNil(try idle.next(timeout: 1))
        let partial = try fixture.peer(); try partial.sendRaw(Data([0,0])); XCTAssertNil(try partial.next(timeout: 1))
        // An authenticated viewer survives the hello deadline.
        try good.send(.list)
        guard case .control(.agents) = try good.next() else { return XCTFail("Expected agents") }
    }
    func testPeerUIDAndSocketOwnerDecisions() {
        XCTAssertTrue(StreamServer.allowsPeer(uid: 501, serverUID: 501))
        XCTAssertFalse(StreamServer.allowsPeer(uid: 502, serverUID: 501))
        XCTAssertTrue(StreamServer.acceptsSocket(mode: S_IFSOCK | 0o600, uid: 501, serverUID: 501))
        XCTAssertFalse(StreamServer.acceptsSocket(mode: S_IFSOCK | 0o600, uid: 502, serverUID: 501))
        XCTAssertFalse(StreamServer.acceptsSocket(mode: S_IFREG | 0o600, uid: 501, serverUID: 501))
    }
    func testUnsafePathsStaleSocketAndActiveSocket() throws {
        let fixture = try StreamTestFixture()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: fixture.server.socketPath))
        XCTAssertThrowsError(try fixture.server.start()) { XCTAssertEqual($0 as? StreamServerError, .unsafeSocket) }
        XCTAssertEqual(try String(contentsOfFile: fixture.server.socketPath, encoding: .utf8), "keep")
        try FileManager.default.removeItem(atPath: fixture.server.socketPath)
        chmod(fixture.runtime.path, 0o755)
        XCTAssertThrowsError(try fixture.server.start()) { XCTAssertEqual($0 as? StreamServerError, .unsafeDirectory) }
        chmod(fixture.runtime.path, 0o700)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try StreamServer.address(fixture.server.socketPath)
        let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }}
        XCTAssertEqual(bound, 0); Darwin.close(fd)
        try fixture.server.start()
        var st = stat(); XCTAssertEqual(lstat(fixture.server.socketPath, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let second = StreamServer(commandDirectory: fixture.commands, factory: fixture.factory, windows: StreamTestWindows(), permission: { true })
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? StreamServerError, .socketInUse) }
        let peer = try fixture.peer(); try peer.authenticate()
        fixture.server.stop(); XCTAssertEqual(lstat(fixture.server.socketPath, &st), -1)
    }
    func testUnsafeTokenAndOversizedWireFrame() throws {
        let fixture = try StreamTestFixture()
        chmod(fixture.runtime.appendingPathComponent("host-token").path, 0o644)
        XCTAssertThrowsError(try fixture.server.start()) { XCTAssertEqual($0 as? StreamServerError, .unsafeToken) }
        chmod(fixture.runtime.appendingPathComponent("host-token").path, 0o600)
        try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate()
        try peer.sendRaw(Data([0,128,0,1])); XCTAssertNil(try peer.next())
    }
    func testListPushesChangesAndOmitsTitles() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate(); try peer.send(.list)
        let expected = StreamAgent(agent: "a", name: "Agent", color_slot: 2, app_name: "Fixture", busy: true, state: .live)
        XCTAssertEqual(try peer.next(), .control(.agents(.init(agents: [expected]))))
        try fixture.targets(name: "New name", busy: false)
        guard case .control(.agents(let push)) = try peer.next() else { return XCTFail("Expected pushed list") }
        XCTAssertEqual(push.agents.first?.name, "New name"); XCTAssertEqual(push.agents.first?.busy, false)
        XCTAssertFalse(String(data: try JSONEncoder().encode(push), encoding: .utf8)!.contains("Secret title"))
        try FileManager.default.removeItem(at: fixture.runtime.appendingPathComponent("targets.json"))
        XCTAssertEqual(try peer.next(), .control(.agents(.init(agents: []))))
    }
    func testSubscribeCursorVideoKeyframeRefusalsAndUnsubscribe() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate()
        try peer.send(.subscribe(.init(agent: "unknown")))
        XCTAssertEqual(try peer.next(), .control(.error(.init(code: .unknown_agent, agent: "unknown"))))
        try peer.send(.subscribe(.init(agent: "a", codec: .hevc)))
        XCTAssertEqual(try peer.next(), .control(.error(.init(code: .codec_unsupported, agent: "a"))))
        try peer.send(.subscribe(.init(agent: "a")))
        guard case .control(.target(let target)) = try peer.next() else { return XCTFail("Expected target first") }
        XCTAssertEqual(target.frame, .init(x: 100, y: 200, width: 800, height: 400)); XCTAssertEqual(target.window_id, 42)
        guard case .control(.cursor(let cursor)) = try peer.next() else { return XCTFail("Expected cursor second") }
        XCTAssertEqual(cursor.x, 25); XCTAssertEqual(cursor.y, 50); XCTAssertEqual(cursor.to_x, 50); XCTAssertEqual(cursor.to_y, 75)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        source.emit(pts: 0, keyframe: false) // cannot reach a new decoder
        source.emit(pts: 1, keyframe: true)
        guard case .video(let first) = try peer.next() else { return XCTFail("Expected video third") }
        XCTAssertEqual(first.header.pts, 1); XCTAssertTrue(first.header.keyframe); XCTAssertNotNil(first.header.format)
        source.emit(pts: 2, keyframe: false)
        guard case .video(let delta) = try peer.next() else { return XCTFail("Expected delta") }
        XCTAssertFalse(delta.header.keyframe); XCTAssertNil(delta.header.format)
        let before = source.keyframeRequests
        try peer.send(.keyframe(.init(agent: "a")))
        streamEventually { source.keyframeRequests > before }
        source.emit(pts: 3)
        guard case .video(let requested) = try peer.next() else { return XCTFail("Expected requested keyframe") }
        XCTAssertTrue(requested.header.keyframe)
        try peer.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        streamEventually { source.stopCount == 1 }
    }
    func testPauseFailsClosedAndEndsActiveSubscription() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate(); try peer.subscribe()
        try fixture.write("status.json", #"{"paused":true}"#)
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .paused))))
        try peer.send(.list)
        XCTAssertEqual(try peer.next(), .control(.agents(.init(agents: []))))
        try peer.send(.subscribe(.init(agent: "a")))
        XCTAssertEqual(try peer.next(), .control(.error(.init(code: .paused, agent: "a"))))
        for malformed in ["{}", #"{"paused":"false"}"#, "bad json"] {
            try fixture.write("status.json", malformed)
            try peer.send(.subscribe(.init(agent: "a")))
            XCTAssertEqual(try peer.next(), .control(.error(.init(code: .paused, agent: "a"))))
        }
        try FileManager.default.removeItem(at: fixture.runtime.appendingPathComponent("status.json"))
        try peer.send(.subscribe(.init(agent: "a")))
        XCTAssertEqual(try peer.next(), .control(.error(.init(code: .paused, agent: "a"))))
        try fixture.write("status.json", #"{"paused":false}"#)
        guard case .control(.agents(let resumed)) = try peer.next() else { return XCTFail("Expected resumed list") }
        XCTAssertEqual(resumed.agents.count, 1)
    }
    func testEndReleaseShutdownAndSourceEndReasons() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate(); try peer.subscribe()
        try fixture.write("targets.json", "[]")
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .released))))
        for reason in [StreamEndReason.disconnected, .stopped, .capture_stopped_by_user, .error] {
            try fixture.targets(); try peer.subscribe()
            let source = try XCTUnwrap(fixture.factory.sources.last)
            source.event(.ended(reason))
            XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: reason))))
        }
        try peer.subscribe()
        fixture.server.stop()
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .stopped))))
        XCTAssertNil(try peer.next())
    }
    func testNoPermissionRefusedWithoutStartingSource() throws {
        let fixture = try StreamTestFixture(permission: false); try fixture.server.start()
        let peer = try fixture.peer(); try peer.authenticate(); try peer.send(.subscribe(.init(agent: "a")))
        XCTAssertEqual(try peer.next(), .control(.error(.init(code: .no_permission, agent: "a"))))
        XCTAssertTrue(fixture.factory.sources.isEmpty)
    }
    func testSharedSourceTargetSwitchAndWindowState() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let first = try fixture.peer(), second = try fixture.peer()
        try first.authenticate(); try second.authenticate(); try first.subscribe(fps: 5); try second.subscribe(fps: 30)
        XCTAssertEqual(fixture.factory.sources.count, 1)
        let source = fixture.factory.sources[0]
        XCTAssertEqual(source.configs.map(\.maxFPS), [5,30])
        source.event(.state(.minimized))
        for peer in [first, second] {
            guard case .control(.target(let target)) = try peer.next() else { return XCTFail("Expected minimized target") }
            XCTAssertEqual(target.state, .minimized)
        }
        source.event(.state(.live))
        for peer in [first, second] {
            guard case .control(.target(let target)) = try peer.next() else { return XCTFail("Expected restored target") }
            XCTAssertEqual(target.state, .live)
        }
        try second.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try second.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        streamEventually { source.configs.last?.maxFPS == 5 }
        try fixture.cursors(window: 43); try fixture.targets(window: 43)
        guard case .control(.target(let changed)) = try first.next() else { return XCTFail("Expected changed target") }
        XCTAssertEqual(changed.window_id, 43)
        guard case .control(.cursor) = try first.next() else { return XCTFail("Expected cursor on new window") }
        streamEventually { source.stopCount == 1 }
        XCTAssertEqual(fixture.factory.sources.last?.windowID, 43)
        first.close()
        streamEventually { fixture.factory.sources.last?.stopCount == 1 }
    }
}
