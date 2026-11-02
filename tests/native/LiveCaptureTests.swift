import AppKit
import CoreMedia
import Darwin
import Foundation
import OCUStream
import ScreenCaptureKit
import XCTest
@testable import ComputerUseHelper

private func syntheticFrame(width: Int = 800, height: Int = 400) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
    let pixels = try XCTUnwrap(image)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height { for x in 0..<width {
        let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
        base[offset] = UInt8(x % 256); base[offset + 1] = UInt8(y % 256); base[offset + 2] = 160; base[offset + 3] = 255
    }}
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return pixels
}
private func frameMetadata(_ time: TimeInterval = 10.1, scale: CGFloat = 1) -> LiveFrameMetadata {
    .init(displayTime: time, contentRect: CGRect(x: 0, y: 0, width: 800, height: 400), contentScale: scale, scaleFactor: 2)
}

final class LiveCaptureTests: XCTestCase {
    private let size = CGSize(width: 800, height: 400)

    func testFreshCompleteAndIdleUseExactlyTheHeldPixels() throws {
        let pixels = try syntheticFrame()
        var now = 10.1
        let buffer = LiveFrameBuffer(now: { now })
        buffer.receive(status: .complete, image: pixels, metadata: frameMetadata())
        XCTAssertTrue(try buffer.frame(after: 10, size: size)?.image === pixels)
        now = 10.2
        buffer.receive(status: .idle, image: nil, metadata: frameMetadata(10.2))
        XCTAssertTrue(try buffer.frame(after: 10.15, size: size)?.image === pixels)
    }
    func testOnlyASampleAfterRequestReceivedWithin250msCanChooseLive() throws {
        let pixels = try syntheticFrame()
        for (sample, received, request) in [(10.0, 10.0, 10.0), (9.9, 10.0, 10.0), (10.1, 10.251, 10.0)] {
            var now = received
            var waited = 0.0
            let buffer = LiveFrameBuffer(now: { now }, wait: { _, remaining in waited += remaining; now += remaining })
            buffer.receive(status: .complete, image: pixels, metadata: frameMetadata(sample))
            XCTAssertNil(try buffer.frame(after: request, size: size))
            XCTAssertLessThanOrEqual(waited, LiveFrameBuffer.freshnessWait)
        }
        // Sample arrived on the deadline; screenshot processing itself may run later.
        var now = 10.25
        let buffer = LiveFrameBuffer(now: { now })
        buffer.receive(status: .complete, image: pixels, metadata: frameMetadata(10.25))
        now = 10.5
        XCTAssertNotNil(try buffer.frame(after: 10, size: size))
    }
    func testRequestWaitsForNextSampleWithoutBlockingStreamQueue() throws {
        let buffer = LiveFrameBuffer(), pixels = try syntheticFrame()
        let arrival = CaptureClock.now(), finished = expectation(description: "fresh sample")
        DispatchQueue(label: "test.screenshot").async {
            XCTAssertNotNil(try? buffer.frame(after: arrival, size: self.size)); finished.fulfill()
        }
        let metadata = frameMetadata(CaptureClock.now())
        buffer.receive(status: .complete, image: pixels, metadata: metadata)
        wait(for: [finished], timeout: 3)
    }
    func testResizedScaledMissingAndNonCompleteFramesFallBack() throws {
        let pixels = try syntheticFrame()
        for scale: CGFloat in [0.5, 2] {
            let buffer = LiveFrameBuffer(now: { 10.1 })
            buffer.receive(status: .complete, image: pixels, metadata: frameMetadata(scale: scale))
            XCTAssertNil(try buffer.frame(after: 10, size: size))
        }
        let buffer = LiveFrameBuffer(now: { 10.1 })
        buffer.receive(status: .complete, image: pixels, metadata: frameMetadata())
        XCTAssertNil(try buffer.frame(after: 10, size: CGSize(width: 900, height: 400)))
        for status in [SCFrameStatus.idle, .blank, .suspended, .started, .stopped] {
            var now = 10.1
            let buffer = LiveFrameBuffer(now: { now }, wait: { _, remaining in now += remaining })
            buffer.receive(status: status, image: pixels, metadata: frameMetadata())
            XCTAssertNil(try buffer.frame(after: 10, size: size))
        }
        var now = 10.1
        let missing = LiveFrameBuffer(now: { now }, wait: { _, remaining in now += remaining })
        missing.receive(status: .complete, image: pixels, metadata: nil)
        XCTAssertNil(try missing.frame(after: 10, size: size))
    }
    func testIdleCannotRevalidateChangedMetadataAndStopClearsPixels() throws {
        let pixels = try syntheticFrame()
        var now = 10.1
        let buffer = LiveFrameBuffer(now: { now }, wait: { _, remaining in now += remaining })
        buffer.receive(status: .complete, image: pixels, metadata: frameMetadata())
        buffer.receive(status: .idle, image: nil, metadata: frameMetadata(10.2, scale: 2))
        XCTAssertNil(try buffer.frame(after: 10, size: size))
        buffer.stop(userStopped: true)
        buffer.stop()
        XCTAssertThrowsError(try buffer.frame(after: 10, size: size)) {
            XCTAssertEqual($0 as? LiveCaptureError, .capture_stopped_by_user)
        }
    }
    func testLiveAndOneOffSyntheticImageHaveIdenticalJPEGDimensionsAndBounds() throws {
        let pixels = try syntheticFrame()
        let live = LiveFrame(image: pixels, metadata: frameMetadata())
        let liveImage = try XCTUnwrap(live.cgImage())
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 800, height: 400,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        let oneOff = try XCTUnwrap(context.makeImage())
        func encode(_ image: CGImage) throws -> Data {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            graphics.imageInterpolation = .high; NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 800, height: 400).fill()
            ApplicationSurfaceImage.draw(image, in: NSRect(x: 0, y: 0, width: 800, height: 400))
            NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(ApplicationSurfaceImage.encode(bitmap, isPNG: false))
        }
        let liveJPEG = try encode(liveImage), screenshotJPEG = try encode(oneOff)
        XCTAssertEqual(liveJPEG, screenshotJPEG)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: liveJPEG))
        XCTAssertEqual(decoded.pixelsWide, 800); XCTAssertEqual(decoded.pixelsHigh, 400)
        let bounds = CGRect(x: -100, y: 200, width: 800, height: 400)
        let a = ApplicationSurfaceImage.metadata(width: 800, height: 400, bounds: bounds, windowCount: 1, source: "live")
        let b = ApplicationSurfaceImage.metadata(width: 800, height: 400, bounds: bounds, windowCount: 1, source: "screenshot")
        XCTAssertEqual(a["data"] as? NSDictionary, b["data"] as? NSDictionary)
        let observations = (a["data"] as? [String: Any])?["observations"] as? [[String: Any]]
        let coordinates = observations?.first?["coordinates"] as? [String: Any]
        XCTAssertEqual(coordinates?["logical_bounds"] as? [[CGFloat]], [[-100, 200], [800, 400]])
    }
}

final class CaptureModeTests: XCTestCase {
    func testDefaultPersistedModesMalformedAndAtomicPrivateWrites() throws {
        let fixture = try StreamTestFixture()
        var logs: [String] = []
        let store = CaptureModeStore(runtime: fixture.runtime, log: { logs.append($0) })
        XCTAssertEqual(store.mode, .live); XCTAssertTrue(logs.isEmpty)
        for mode in [CaptureMode.live, .screenshots, .live] {
            let before = try? FileManager.default.attributesOfItem(atPath: store.url.path)[.systemFileNumber] as? NSNumber
            try store.set(mode)
            var st = stat(); XCTAssertEqual(lstat(store.url.path, &st), 0)
            XCTAssertEqual(st.st_mode & 0o777, 0o600)
            XCTAssertNotEqual(before?.uint64Value, UInt64(st.st_ino))
            XCTAssertEqual(CaptureModeStore(runtime: fixture.runtime).mode, mode)
        }
        let finished = expectation(description: "atomic reader")
        DispatchQueue(label: "test.mode-reader").async {
            for _ in 0..<100 {
                let data = try? Data(contentsOf: store.url)
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                XCTAssertTrue(["live", "screenshots"].contains(object?["mode"] ?? ""))
            }
            finished.fulfill()
        }
        for index in 0..<20 { try store.set(index % 2 == 0 ? .live : .screenshots) }
        wait(for: [finished], timeout: 3)
        for malformed in ["", "{", "{}", #"{"mode":"unknown"}"#, #"{"mode":null}"#] {
            try fixture.write("capture-mode.json", malformed)
            logs = []
            let bad = CaptureModeStore(runtime: fixture.runtime, log: { logs.append($0) })
            XCTAssertEqual(bad.mode, .screenshots); _ = bad.mode; _ = bad.mode
            XCTAssertEqual(logs.count, 1)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.runtime.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".capture-mode-") })
    }
}
