import CoreMedia
import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

/// Entirely synthetic pixel buffers: no apps, screen capture or permission requests.
final class StreamEncoderTests: XCTestCase {
    func testRealEncoderForcedKeyframesCarryAVCCAndParameterSets() throws {
        let lock = NSLock()
        var packets: [StreamEncodedSample] = [], failed = false
        let encoder = StreamEncoder { event in
            lock.lock()
            switch event {
            case .sample(let sample): packets.append(sample)
            case .ended: failed = true
            default: break
            }
            lock.unlock()
        }
        defer { encoder.stop() }
        // Feed at the stream's 15 fps while waiting. VT's low-latency rate
        // controller drops early frames with status=noErr, FrameDropped and no
        // sample. Waiting after a single submission cannot recover a dropped IDR.
        let deadline = Date(timeIntervalSinceNow: 3)
        var requestedSecond = false, index = 0
        while Date() < deadline {
            lock.lock(); let keyframes = packets.filter(\.keyframe).count; lock.unlock()
            if keyframes >= 2 { break }
            if keyframes == 1 && !requestedSecond { encoder.requestKeyframe(); requestedSecond = true }
            var image: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 800, 400, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
            let pixels = try XCTUnwrap(image)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<400 { for x in 0..<800 {
                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                base[offset] = UInt8(index % 256); base[offset + 1] = 80; base[offset + 2] = 160; base[offset + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(pixels, [])
            try encoder.encode(pixels, pts: CMTime(value: Int64(index), timescale: 15))
            index += 1
            Thread.sleep(forTimeInterval: 1.0 / 15)
        }
        lock.lock(); let samples = Array(packets.filter(\.keyframe).prefix(2)), error = failed; lock.unlock()
        XCTAssertFalse(error); XCTAssertTrue(requestedSecond); XCTAssertEqual(samples.count, 2)
        for sample in samples {
            XCTAssertTrue(sample.keyframe)
            let format = try XCTUnwrap(sample.format)
            XCTAssertFalse(format.sps.isEmpty); XCTAssertFalse(format.pps.isEmpty)
            XCTAssertEqual(format.sps.first?.first.map { $0 & 0x1f }, 7)
            XCTAssertEqual(format.pps.first?.first.map { $0 & 0x1f }, 8)
            var offset = 0
            while offset < sample.data.count {
                XCTAssertGreaterThanOrEqual(sample.data.count - offset, 4)
                guard sample.data.count - offset >= 4 else { break }
                let length = sample.data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                XCTAssertGreaterThan(length, 0)
                XCTAssertLessThanOrEqual(offset + 4 + length, sample.data.count)
                offset += 4 + length
            }
            XCTAssertEqual(offset, sample.data.count)
        }
    }
}
