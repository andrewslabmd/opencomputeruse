import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

final class StreamWatchersTests: XCTestCase {
    private func watchers(_ peer: StreamTestPeer, equal expected: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .control(.agents(let list)) = try peer.next() else { return XCTFail("Expected watcher list", file: file, line: line) }
        XCTAssertEqual(list.agents.first?.watchers, expected, file: file, line: line)
        XCTAssertFalse(String(data: try JSONEncoder().encode(list), encoding: .utf8)!.contains("Secret title"), file: file, line: line)
    }
    func testNamesFollowSubscriptionsDeduplicateAndAreBounded() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let observer = try fixture.peer(); try observer.authenticate(client: StreamWatchers.appClient)
        try observer.send(.list); try watchers(observer, equal: [])
        let first = try fixture.peer(), duplicate = try fixture.peer(), third = try fixture.peer()
        try first.authenticate(client: "botfactory"); try duplicate.authenticate(client: "botfactory")
        // Unicode extended grapheme clusters count as characters, matching Swift String.prefix.
        let long = String(repeating: "🧑🏽‍💻", count: 65)
        let bounded = String(long.prefix(64))
        try third.authenticate(client: long)
        try first.subscribe(); try watchers(observer, equal: ["botfactory"])
        try duplicate.subscribe()
        try third.subscribe(); try watchers(observer, equal: ["botfactory", bounded].sorted())
        try first.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try first.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        // An explicit list makes the de-duplication assertion independent of push timing.
        try observer.send(.list); try watchers(observer, equal: ["botfactory", bounded].sorted())
        duplicate.close(); try watchers(observer, equal: [bounded])
        third.close(); try watchers(observer, equal: [])
        // Merely authenticating or listing never counts as watching.
        try observer.send(.list); try watchers(observer, equal: [])
    }
    func testOwnAppNameIsPublishedAndRefusedSubscriptionsDoNotWatch() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let observer = try fixture.peer(); try observer.authenticate(); try observer.send(.list)
        try watchers(observer, equal: [])
        let app = try fixture.peer(); try app.authenticate(client: StreamWatchers.appClient)
        try app.send(.subscribe(.init(agent: "a", codec: .hevc)))
        XCTAssertEqual(try app.next(), .control(.error(.init(code: .codec_unsupported, agent: "a"))))
        try observer.send(.list); try watchers(observer, equal: [])
        try app.subscribe(); try watchers(observer, equal: [StreamWatchers.appClient])
        try app.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try app.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        try watchers(observer, equal: [])
    }
    func testTheAppsOwnConnectionIsLeftOutByProcessNotByName() throws {
        // Peers in this test are this process; as the owner they never count as watchers.
        let fixture = try StreamTestFixture()
        fixture.server = StreamServer(commandDirectory: fixture.commands, factory: fixture.factory, windows: StreamTestWindows(),
                                      permission: { true }, ownerPID: getpid())
        try fixture.server.start()
        let observer = try fixture.peer(); try observer.authenticate(); try observer.send(.list)
        try watchers(observer, equal: [])
        let pip = try fixture.peer(); try pip.authenticate(client: "botfactory")
        try pip.subscribe()
        try observer.send(.list); try watchers(observer, equal: [])
    }
    func testBothCodecsShareOneSourceAndEachSubscriberGetsItsCodec() throws {
        let fixture = try StreamTestFixture(); fixture.factory.hevcSupported = true
        try fixture.server.start()
        let h264 = try fixture.peer(), hevc = try fixture.peer(), observer = try fixture.peer()
        try observer.authenticate(); try observer.send(.list); try watchers(observer, equal: [])
        try h264.authenticate(client: "H264 viewer"); try hevc.authenticate(client: "botfactory")
        try h264.subscribe(fps: 15); try watchers(observer, equal: ["H264 viewer"])
        try hevc.send(.subscribe(.init(agent: "a", max_fps: 30, max_long_edge: 400, codec: .hevc)))
        guard case .control(.target) = try hevc.next(), case .control(.cursor) = try hevc.next() else { return XCTFail("Expected HEVC target and cursor") }
        try watchers(observer, equal: ["H264 viewer", "botfactory"])
        XCTAssertEqual(fixture.factory.sources.count, 1)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        XCTAssertEqual(source.configs.last?.maxFPS, 30)
        XCTAssertEqual(source.configs.last?.encoders.count, 2)
        XCTAssertNil(source.configs.last?.maxLongEdge)
        XCTAssertEqual(source.configs.last?.encoders[.hevc]?.maxLongEdge, 400)
        source.emit(pts: 1, keyframe: true, codec: .h264)
        source.emit(pts: 2, keyframe: true, codec: .hevc)
        guard case .video(let first) = try h264.next(), case .video(let second) = try hevc.next() else { return XCTFail("Expected encoded frames") }
        XCTAssertEqual(first.header.codec, .h264); XCTAssertEqual(first.header.pts, 1)
        XCTAssertEqual(second.header.codec, .hevc); XCTAssertEqual(second.header.pts, 2)
        try hevc.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try hevc.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        try watchers(observer, equal: ["H264 viewer"])
        streamEventually { source.configs.last?.encoders.count == 1 }
        XCTAssertEqual(source.stopCount, 0)
        source.emit(pts: 3, keyframe: true)
        guard case .video(let continued) = try h264.next() else { return XCTFail("H.264 must continue") }
        XCTAssertEqual(continued.header.pts, 3)
    }
}
