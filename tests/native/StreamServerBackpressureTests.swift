import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

final class StreamServerBackpressureTests: XCTestCase {
    func testSlowViewerDropsAndResumesAtKeyframeWhileFastViewerGetsEveryFrame() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let slow = try fixture.peer(receiveBuffer: 4096), fast = try fixture.peer()
        try slow.authenticate(); try fast.authenticate(); try slow.subscribe(); try fast.subscribe()
        let source = try XCTUnwrap(fixture.factory.sources.first)
        let initialRequests = source.keyframeRequests
        // One MiB samples force a real partial write to the stalled Unix peer.
        // Each fast read completes before the next sample is produced.
        for n in 0..<20 {
            source.emit(pts: Double(n), size: 1024 * 1024)
            guard case .video(let video) = try fast.next() else { return XCTFail("Expected fast video") }
            XCTAssertEqual(video.header.pts, Double(n))
        }
        // No more than the partially written frame survives a drop. Draining it
        // causes a new IDR request; all later deltas must be suppressed until IDR.
        var received: [Double] = []
        while true {
            do {
                guard let message = try slow.next(timeout: 0.1) else { return XCTFail("Slow client disconnected") }
                guard case .video(let video) = message else { return XCTFail("Expected slow video") }
                received.append(video.header.pts)
            } catch is StreamTestTimeout { break }
        }
        XCTAssertFalse(received.isEmpty)
        XCTAssertLessThan(received.count, 20)
        streamEventually { source.keyframeRequests > initialRequests }
        // Even a producer that ignores the keyframe request cannot leak deltas.
        source.emit(pts: 20, keyframe: false)
        guard case .video(let fastDelta) = try fast.next() else { return XCTFail("Expected fast delta") }
        XCTAssertEqual(fastDelta.header.pts, 20)
        XCTAssertThrowsError(try slow.next(timeout: 0.05)) { XCTAssertTrue($0 is StreamTestTimeout) }
        source.emit(pts: 21)
        for peer in [slow, fast] {
            guard case .video(let video) = try peer.next() else { return XCTFail("Expected recovery IDR") }
            XCTAssertEqual(video.header.pts, 21); XCTAssertTrue(video.header.keyframe)
            XCTAssertNotNil(video.header.format)
        }
        source.emit(pts: 22)
        for peer in [slow, fast] {
            guard case .video(let video) = try peer.next() else { return XCTFail("Expected recovered delta") }
            XCTAssertEqual(video.header.pts, 22); XCTAssertFalse(video.header.keyframe)
        }
        XCTAssertEqual(fixture.factory.sources.count, 1)
    }
    func testControlQueueOverflowDisconnectsWithoutStallingOtherViewer() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let slow = try fixture.peer(receiveBuffer: 4096), fast = try fixture.peer()
        try slow.authenticate(); try fast.authenticate(); try slow.subscribe()
        let source = try XCTUnwrap(fixture.factory.sources.first)
        source.emit(pts: 0, size: 1024 * 1024)
        // The blocked video holds the writer. 257 list replies in one read exceed
        // the specified 256-control queue limit before a writer can run again.
        var requests = Data()
        for _ in 0...StreamServer.controlQueueLimit { requests.append(try StreamFraming.encode(.control(.list))) }
        try slow.sendRaw(requests)
        streamEventually { source.stopCount == 1 }
        // Drain bytes already accepted by the kernel and observe the disconnect.
        // A partial final video is expected when a connection is forcibly closed.
        var data = [UInt8](repeating: 0, count: 64 * 1024)
        var closed = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !closed {
            let count = Darwin.read(slow.fd, &data, data.count)
            if count == 0 || (count < 0 && errno == ECONNRESET) { closed = true }
            else if count < 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertTrue(closed)
        try fast.send(.list)
        guard case .control(.agents(let list)) = try fast.next() else { return XCTFail("Expected responsive fast client") }
        XCTAssertEqual(list.agents.count, 1)
    }
    func testPauseWithdrawsQueuedVideoAndNoNewSourceEventsReachViewer() throws {
        let fixture = try StreamTestFixture(); try fixture.server.start()
        let peer = try fixture.peer(receiveBuffer: 4096); try peer.authenticate(); try peer.subscribe()
        let source = try XCTUnwrap(fixture.factory.sources.first)
        for n in 0..<3 { source.emit(pts: Double(n), size: 1024 * 1024) }
        try fixture.write("status.json", #"{"paused":true}"#)
        // Refresh happens before each source event as well as on the 50ms poll.
        source.emit(pts: 3)
        var frames: [Double] = []
        while let message = try peer.next() {
            if case .video(let video) = message { frames.append(video.header.pts) }
            else {
                XCTAssertEqual(message, .control(.end(.init(agent: "a", reason: .paused))))
                break
            }
        }
        XCTAssertLessThan(frames.count, 3)
        XCTAssertFalse(frames.contains(3))
        XCTAssertEqual(source.stopCount, 1)
        try peer.send(.list)
        XCTAssertEqual(try peer.next(), .control(.agents(.init(agents: []))))
    }
}
