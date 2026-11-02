import Foundation
import OCUStream
import ScreenCaptureKit
import XCTest
@testable import ComputerUseHelper

private final class LiveTestWindows: StreamWindowProvider {
    var state: StreamTargetState = .live
    var closed = false
    func window(id: UInt32, pid: Int32) -> StreamWindowInfo? {
        closed ? nil : .init(frame: .init(x: 100, y: 200, width: 800, height: 400), state: state)
    }
}

final class LiveStreamServerTests: XCTestCase {
    private func start(_ fixture: StreamTestFixture, windows: StreamWindowProvider = StreamTestWindows(), permission: Bool = true) throws {
        fixture.server = StreamServer(commandDirectory: fixture.commands, factory: fixture.factory, windows: windows,
            permission: { permission }, captureMode: CaptureModeStore(runtime: fixture.runtime))
        try fixture.server.start()
    }
    func testTargetsModeSwitchPauseAndWithdrawalControlAgentOnlyStreams() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        streamEventually(timeout: 1) { fixture.factory.sources.count == 1 }
        let first = try XCTUnwrap(fixture.factory.sources.first)
        XCTAssertEqual(first.windowID, 42)
        XCTAssertEqual(first.configs.first, .init(maxFPS: 15, maxLongEdge: nil, codec: .h264, encode: false))
        try fixture.server.setCaptureMode(.screenshots)
        streamEventually(timeout: 1) { first.stopCount == 1 }
        XCTAssertEqual(fixture.factory.sources.count, 1)
        try fixture.server.setCaptureMode(.live)
        streamEventually(timeout: 1) { fixture.factory.sources.count == 2 }
        let second = fixture.factory.sources[1]
        try fixture.write("status.json", #"{"paused":true}"#)
        streamEventually(timeout: 1) { second.stopCount == 1 }
        try fixture.write("status.json", #"{"paused":false}"#)
        streamEventually(timeout: 1) { fixture.factory.sources.count == 3 }
        let third = fixture.factory.sources[2]
        try fixture.write("targets.json", "[]")
        streamEventually(timeout: 1) { third.stopCount == 1 }
        try fixture.targets(window: 43)
        streamEventually(timeout: 1) { fixture.factory.sources.last?.windowID == 43 }
        XCTAssertEqual(fixture.factory.sources.count, 4)
    }
    func testLiveAndViewerShareSourceHigherRateWinsAndOnlyViewerEncodes() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        let peer = try fixture.peer(); try peer.authenticate(); try peer.subscribe(fps: 5)
        XCTAssertEqual(fixture.factory.sources.count, 1)
        XCTAssertEqual(source.configs.last?.maxFPS, 15); XCTAssertEqual(source.configs.last?.encode, true)
        let second = try fixture.peer(); try second.authenticate(); try second.subscribe(fps: 30)
        XCTAssertEqual(fixture.factory.sources.count, 1)
        XCTAssertEqual(source.configs.last?.maxFPS, 30)
        try fixture.server.setCaptureMode(.screenshots)
        XCTAssertEqual(source.stopCount, 0); XCTAssertEqual(source.configs.last?.encode, true)
        try second.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try second.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        streamEventually { source.configs.last?.maxFPS == 5 }
        try fixture.server.setCaptureMode(.live)
        try peer.send(.unsubscribe(.init(agent: "a")))
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .unsubscribed))))
        streamEventually { source.configs.last?.encode == false }
        XCTAssertEqual(source.stopCount, 0); XCTAssertEqual(source.configs.last?.maxFPS, 15)
        try fixture.server.setCaptureMode(.screenshots)
        streamEventually(timeout: 1) { source.stopCount == 1 }
    }
    func testViewerResolutionLimitIsPreservedAlongsideFullResolutionLiveCapture() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        let source = try XCTUnwrap(fixture.factory.sources.first), peer = try fixture.peer()
        try peer.authenticate(); try peer.send(.subscribe(.init(agent: "a", max_long_edge: 400)))
        guard case .control(.target) = try peer.next(), case .control(.cursor) = try peer.next() else { return XCTFail("Expected target and cursor") }
        XCTAssertEqual(fixture.factory.sources.count, 1)
        XCTAssertNil(source.configs.last?.maxLongEdge)
        XCTAssertEqual(source.configs.last?.encoderMaxLongEdge, 400)
        try fixture.server.setCaptureMode(.screenshots)
        XCTAssertEqual(source.configs.last?.maxLongEdge, 400)
        XCTAssertNil(source.configs.last?.encoderMaxLongEdge)
        XCTAssertEqual(source.stopCount, 0)
    }
    func testUserStoppedBlocksAllCaptureModesAndMultiWindowUntilNewTargetOrViewer() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        var source = try XCTUnwrap(fixture.factory.sources.first)
        source.event(.ended(.capture_stopped_by_user))
        XCTAssertThrowsError(try fixture.server.checkCaptureAllowed(windowIDs: [42, 99], pid: 123)) {
            XCTAssertEqual($0 as? LiveCaptureError, .capture_stopped_by_user)
        }
        try fixture.write("status.json", #"{"paused":true}"#)
        XCTAssertThrowsError(try fixture.server.checkCaptureAllowed(windowIDs: [42], pid: 123))
        try fixture.write("status.json", #"{"paused":false}"#)
        try fixture.server.setCaptureMode(.screenshots)
        XCTAssertThrowsError(try fixture.server.liveFrame(windowIDs: [42], pid: 123, after: CaptureClock.now(), size: .init(width: 800, height: 400)))
        try fixture.server.setCaptureMode(.live)
        XCTAssertEqual(fixture.factory.sources.count, 1)
        let peer = try fixture.peer(); try peer.authenticate(); try peer.subscribe()
        XCTAssertEqual(fixture.factory.sources.count, 2)
        XCTAssertNoThrow(try fixture.server.checkCaptureAllowed(windowIDs: [42], pid: 123))
        source = fixture.factory.sources[1]
        source.event(.ended(.capture_stopped_by_user))
        XCTAssertEqual(try peer.next(), .control(.end(.init(agent: "a", reason: .capture_stopped_by_user))))
        try fixture.targets(window: 43)
        XCTAssertNoThrow(try fixture.server.checkCaptureAllowed(windowIDs: [42, 43], pid: 123))
        streamEventually { fixture.factory.sources.last?.windowID == 43 }
        source = fixture.factory.sources.last!
        source.event(.ended(.capture_stopped_by_user))
        try fixture.write("targets.json", "[]")
        XCTAssertNoThrow(try fixture.server.checkCaptureAllowed(windowIDs: [43], pid: 123))
        try fixture.targets(window: 43)
        streamEventually { fixture.factory.sources.count == 4 }
    }
    func testFailedLiveStreamIsNotRestartedUntilTheTargetChanges() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        source.event(.ended(.error))
        Thread.sleep(forTimeInterval: 0.3) // six 50 ms polls
        XCTAssertEqual(fixture.factory.sources.count, 1, "an errored live stream is not retried every poll")
        XCTAssertNoThrow(try fixture.server.checkCaptureAllowed(windowIDs: [42], pid: 123), "one-off screenshots still work")
        try fixture.targets(window: 43)
        streamEventually { fixture.factory.sources.last?.windowID == 43 }
    }
    func testFrameChoiceRejectsTwoWindowsOtherPIDHiddenAndScreenshotsMode() throws {
        let fixture = try StreamTestFixture(), windows = LiveTestWindows(); try start(fixture, windows: windows)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 800, 400, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        let arrival = CaptureClock.now()
        source.liveFrames.receive(status: .complete, image: image, metadata: .init(displayTime: CaptureClock.now(),
            contentRect: .init(x: 0, y: 0, width: 800, height: 400), contentScale: 1, scaleFactor: 2))
        let size = CGSize(width: 800, height: 400)
        XCTAssertNotNil(try fixture.server.liveFrame(windowIDs: [42], pid: 123, after: arrival, size: size))
        for ids: Set<UInt32> in [[42, 99], [99], []] {
            XCTAssertNil(try fixture.server.liveFrame(windowIDs: ids, pid: 123, after: arrival, size: size))
        }
        XCTAssertNil(try fixture.server.liveFrame(windowIDs: [42], pid: 999, after: arrival, size: size))
        windows.state = .hidden_from_capture
        XCTAssertNil(try fixture.server.liveFrame(windowIDs: [42], pid: 123, after: arrival, size: size))
        windows.state = .live
        try fixture.server.setCaptureMode(.screenshots)
        XCTAssertNil(try fixture.server.liveFrame(windowIDs: [42], pid: 123, after: arrival, size: size))
    }
    func testWindowClosingStopsAgentOnlyAndPermissionNeverStartsCapture() throws {
        let denied = try StreamTestFixture(); try start(denied, permission: false)
        XCTAssertTrue(denied.factory.sources.isEmpty)
        let fixture = try StreamTestFixture(), windows = LiveTestWindows(); try start(fixture, windows: windows)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        windows.closed = true
        streamEventually(timeout: 1) { source.stopCount == 1 }
        XCTAssertEqual(fixture.factory.sources.count, 1)
    }
    func testContentChangeDoesNotRestartUntilViewerOrNewTargetAndAllowsOneOff() throws {
        let fixture = try StreamTestFixture(); try start(fixture)
        let source = try XCTUnwrap(fixture.factory.sources.first)
        source.event(.contentChanged)
        XCTAssertNoThrow(try fixture.server.checkCaptureAllowed(windowIDs: [42], pid: 123))
        XCTAssertNil(try fixture.server.liveFrame(windowIDs: [42], pid: 123, after: CaptureClock.now(), size: .init(width: 800, height: 400)))
        XCTAssertEqual(fixture.factory.sources.count, 1)
        try fixture.targets(window: 43)
        streamEventually { fixture.factory.sources.count == 2 }
    }
}
