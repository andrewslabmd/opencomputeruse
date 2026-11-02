import CoreMedia
import Foundation
import OCUStream
import ScreenCaptureKit
import XCTest
@testable import ComputerUseHelper

private final class CaptureDriverFake: StreamCaptureDriver {
    var queue: DispatchQueue!
    var output: ((SCFrameStatus, CVPixelBuffer?, CMTime) -> Void)?
    var stopped: ((Error) -> Void)?
    var updates: [(StreamCaptureSize, StreamFrameConfiguration)] = []
    var stopCount = 0
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, queue: DispatchQueue,
               output: @escaping (SCFrameStatus, CVPixelBuffer?, CMTime) -> Void,
               stopped: @escaping (Error) -> Void, ready: @escaping (Result<CGSize, Error>) -> Void) {
        self.queue = queue; self.output = output; self.stopped = stopped
        ready(.success(CGSize(width: 800, height: 400)))
    }
    func update(size: StreamCaptureSize, configuration: StreamFrameConfiguration, completion: @escaping (Error?) -> Void) {
        updates.append((size, configuration)); completion(nil)
    }
    func stop() { stopCount += 1 }
}
private final class CaptureEncoderFake: StreamFrameEncoder {
    var requested = false
    var count = 0
    var stopCount = 0
    var receive: ((StreamFrameEvent) -> Void)?
    func requestKeyframe() { requested = true }
    func encode(_ image: CVPixelBuffer, pts: CMTime) throws {
        count += 1
        receive?(.sample(.init(pts: CMTimeGetSeconds(pts), keyframe: requested,
            format: requested ? .init(sps: [Data([7])], pps: [Data([8])]) : nil, data: Data([1]))))
        requested = false
    }
    func stop() { stopCount += 1 }
}

final class StreamCaptureTests: XCTestCase {
    private let live = StreamWindowInfo(frame: .init(x: 0, y: 0, width: 800, height: 400))
    private let request = StreamFrameConfiguration(maxFPS: 15, maxLongEdge: nil, codec: .h264)
    func testMeasuredStateMapping() {
        XCTAssertEqual(StreamCapture.state(status: .suspended, window: nil, previous: .live), .closed)
        var info = live; info.state = .hidden
        XCTAssertEqual(StreamCapture.state(status: .suspended, window: info, previous: .live), .hidden)
        XCTAssertEqual(StreamCapture.state(status: .suspended, window: live, previous: .live), .minimized)
        XCTAssertEqual(StreamCapture.state(status: .complete, window: live, previous: .minimized), .live)
        XCTAssertEqual(StreamCapture.state(status: .idle, window: live, previous: .hidden), .hidden)
        XCTAssertEqual(StreamCapture.state(status: .idle, window: live, previous: .live), .live)
        info.state = .hidden_from_capture
        XCTAssertEqual(StreamCapture.state(status: .complete, window: info, previous: .live), .hidden_from_capture)
    }
    func testSizingAndSCConfiguration() {
        XCTAssertEqual(StreamCaptureSize.output(CGSize(width: 1440, height: 900), maxLongEdge: nil), .init(width: 1440, height: 900))
        XCTAssertEqual(StreamCaptureSize.output(CGSize(width: 1440, height: 900), maxLongEdge: 720), .init(width: 720, height: 450))
        XCTAssertEqual(StreamCaptureSize.output(CGSize(width: 900, height: 1440), maxLongEdge: 720), .init(width: 450, height: 720))
        XCTAssertEqual(StreamCaptureSize.output(CGSize(width: 800, height: 400), maxLongEdge: 1440), .init(width: 800, height: 400))
        let config = SystemStreamCaptureDriver.configuration(size: .init(width: 800, height: 400), request: request)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 15))
        XCTAssertTrue(config.includeChildWindows); XCTAssertTrue(config.scalesToFit); XCTAssertTrue(config.ignoreShadowsSingleWindow)
        XCTAssertFalse(config.showsCursor); XCTAssertFalse(config.capturesAudio); XCTAssertEqual(config.queueDepth, 3)
        XCTAssertFalse(SystemStreamFrameSourceFactory().supports(.hevc))
    }
    func testNoPermissionNeverStartsCapture() {
        let driver = CaptureDriverFake()
        let source = StreamCapture(driver: driver, permission: { false })
        XCTAssertThrowsError(try source.start(windowID: 42, configuration: request) { _ in }) {
            XCTAssertEqual($0 as? StreamSourceError, .noPermission)
        }
        XCTAssertNil(driver.queue)
    }
    func testResizeDebounceAndConfigureWithoutRestart() throws {
        let driver = CaptureDriverFake(), ready = expectation(description: "ready")
        let source = StreamCapture(driver: driver, permission: { true }, window: { _ in self.live })
        try source.start(windowID: 42, configuration: request) { _ in ready.fulfill() }
        // First complete frame announces live. No image/encoder or OS capture is needed.
        streamEventually { driver.queue != nil }
        driver.queue.async { driver.output?(.complete, nil, .zero) }
        wait(for: [ready], timeout: 3)
        driver.queue.sync {
            source.considerResize(CGSize(width: 1000, height: 500), at: 0)
            source.considerResize(CGSize(width: 1000, height: 500), at: 0.299)
            XCTAssertTrue(driver.updates.isEmpty)
            source.considerResize(CGSize(width: 1200, height: 600), at: 0.299)
            source.considerResize(CGSize(width: 1200, height: 600), at: 0.598)
            XCTAssertTrue(driver.updates.isEmpty)
            source.considerResize(CGSize(width: 1200, height: 600), at: 0.600)
            XCTAssertEqual(driver.updates.last?.0, .init(width: 1200, height: 600))
        }
        source.configure(.init(maxFPS: 30, maxLongEdge: 600, codec: .h264))
        driver.queue.sync {
            XCTAssertEqual(driver.updates.last?.0, .init(width: 600, height: 300))
            XCTAssertEqual(driver.updates.last?.1.maxFPS, 30)
            XCTAssertEqual(driver.stopCount, 0)
        }
        source.stop(); driver.queue.sync { XCTAssertEqual(driver.stopCount, 1) }
    }
    func testKeyframeAndFramesContinueWhileNativeQueueBlockedAndStopDoesNotWaitForReceiver() throws {
        let nativeQueue = DispatchQueue(label: "test.blocked-native"), releaseNative = DispatchSemaphore(value: 0)
        nativeQueue.async { releaseNative.wait() }
        defer { releaseNative.signal() }
        let driver = CaptureDriverFake(), encoder = CaptureEncoderFake()
        let gotFrame = expectation(description: "encoded frame"), receiverEntered = DispatchSemaphore(value: 0)
        let releaseReceiver = DispatchSemaphore(value: 0)
        let source = StreamCapture(driver: driver, permission: { true }, window: { _ in self.live }, makeEncoder: { receive in encoder.receive = receive; return encoder })
        try source.start(windowID: 42, configuration: request) { event in
            if case .sample(let sample) = event {
                XCTAssertTrue(sample.keyframe); XCTAssertNotNil(sample.format)
                XCTAssertFalse(Thread.isMainThread)
                gotFrame.fulfill(); receiverEntered.signal(); releaseReceiver.wait()
            }
        }
        streamEventually { driver.queue != nil }
        source.requestKeyframe()
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 800, 400, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        driver.queue.async { driver.output?(.complete, image, .zero) }
        wait(for: [gotFrame], timeout: 3)
        XCTAssertEqual(receiverEntered.wait(timeout: .now() + 3), .success)
        // The callback is blocked; stop must still return immediately to the server.
        source.stop()
        releaseReceiver.signal()
        driver.queue.sync { XCTAssertEqual(driver.stopCount, 1); XCTAssertEqual(encoder.stopCount, 1) }
    }
    func testSharingNoneSuppressesFramesAndStopErrors() throws {
        let driver = CaptureDriverFake(), encoder = CaptureEncoderFake()
        var hidden = live; hidden.state = .hidden_from_capture
        let changed = expectation(description: "hidden")
        let source = StreamCapture(driver: driver, permission: { true }, window: { _ in hidden }, makeEncoder: { encoder.receive = $0; return encoder })
        try source.start(windowID: 42, configuration: request) { if case .state(.hidden_from_capture) = $0 { changed.fulfill() } }
        streamEventually { driver.queue != nil }
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 800, 400, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        driver.queue.async { driver.output?(.complete, image, .zero) }
        wait(for: [changed], timeout: 3)
        driver.queue.sync { XCTAssertEqual(encoder.count, 0) }
        source.stop()
        XCTAssertEqual(StreamCapture.endReason(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)), .capture_stopped_by_user)
        XCTAssertEqual(StreamCapture.endReason(NSError(domain: SCStreamErrorDomain, code: -1)), .error)
    }
    func testDriverStopErrorEndsAndReleasesCapture() throws {
        for (code, reason) in [(SCStreamError.Code.userStopped.rawValue, StreamEndReason.capture_stopped_by_user), (-1, .error)] {
            let driver = CaptureDriverFake(), ended = expectation(description: "ended \(reason)")
            let source = StreamCapture(driver: driver, permission: { true }, window: { _ in self.live })
            try source.start(windowID: 42, configuration: request) { event in
                if case .ended(let actual) = event { XCTAssertEqual(actual, reason); ended.fulfill() }
            }
            streamEventually { driver.queue != nil }
            driver.queue.async { driver.stopped?(NSError(domain: SCStreamErrorDomain, code: code)) }
            wait(for: [ended], timeout: 3)
            driver.queue.sync { XCTAssertEqual(driver.stopCount, 1) }
        }
    }
    func testServerRetriesMissingTokenAndLogsReasonOnce() throws {
        let fixture = try StreamTestFixture()
        let token = fixture.runtime.appendingPathComponent("host-token")
        try FileManager.default.removeItem(at: token)
        let failed = expectation(description: "first failure"), started = expectation(description: "started")
        let lifecycle = StreamServerLifecycle(start: {
            try fixture.server.start(); started.fulfill()
        }, stop: { fixture.server.stop() }, log: { _ in failed.fulfill() })
        lifecycle.start(); defer { lifecycle.stop() }
        wait(for: [failed], timeout: 3)
        // At least one retry sees the same missing-token failure without logging again.
        Thread.sleep(forTimeInterval: StreamServerLifecycle.retryInterval * 1.1)
        try StreamTestFixture.token.write(to: token, atomically: true, encoding: .utf8)
        chmod(token.path, 0o600)
        wait(for: [started], timeout: 3)
        let peer = try fixture.peer(); try peer.authenticate()
    }
}
