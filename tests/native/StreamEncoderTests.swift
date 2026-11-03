import CoreMedia
import Foundation
import OCUStream
import XCTest
import VideoToolbox
@testable import ComputerUseHelper

/// Entirely synthetic pixel buffers: no apps, screen capture or permission requests.
final class StreamEncoderTests: XCTestCase {
    func testHEVCKeyframesCarryParameterSetsAndDecodeWithVideoToolbox() throws {
        let supported = SystemStreamFrameSourceFactory().supports(.hevc)
        print("supports(.hevc) = \(supported) (hardware encoder creation with low-latency rate control)")
        guard supported else { throw XCTSkip("supports(.hevc) is false: this Mac cannot create the requested HEVC hardware encoder") }
        let lock = NSLock()
        var packets: [StreamEncodedSample] = [], failed = false
        let encoder = StreamEncoder(codec: .hevc) { event in
            lock.withLock {
                if case .sample(let packet) = event { packets.append(packet) }
                if case .ended = event { failed = true }
            }
        }
        defer { encoder.stop() }
        let deadline = Date(timeIntervalSinceNow: 3) // Test timeout, our choice.
        var index = 0
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 800, 400, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let pixels = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while Date() < deadline && lock.withLock({ packets.filter(\.keyframe).count < 2 && !failed }) {
            encoder.requestKeyframe()
            try encoder.encode(pixels, pts: CMTime(value: Int64(index), timescale: 15))
            index += 1
            Thread.sleep(forTimeInterval: 1.0 / 15)
        }
        let samples = lock.withLock { packets.filter(\.keyframe) }
        XCTAssertFalse(lock.withLock { failed })
        XCTAssertGreaterThanOrEqual(samples.count, 2)
        for packet in samples {
            XCTAssertEqual(packet.codec, .hevc)
            let format = try XCTUnwrap(packet.format)
            let vps = try XCTUnwrap(format.vps)
            XCTAssertFalse(vps.isEmpty); XCTAssertFalse(format.sps.isEmpty); XCTAssertFalse(format.pps.isEmpty)
            XCTAssertEqual(vps.first?.first.map { ($0 >> 1) & 0x3f }, 32)
            XCTAssertEqual(format.sps.first?.first.map { ($0 >> 1) & 0x3f }, 33)
            XCTAssertEqual(format.pps.first?.first.map { ($0 >> 1) & 0x3f }, 34)
            try decodeHEVC(packet, sets: vps + format.sps + format.pps)
        }
    }
    private func decodeHEVC(_ packet: StreamEncodedSample, sets: [Data]) throws {
        // Own copies keep every parameter set alive through format-description creation.
        let storage = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count); return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        var description: CMFormatDescription?
        let pointers = storage.map { UnsafePointer($0) }, sizes = sets.map(\.count)
        XCTAssertEqual(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
            parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4,
            extensions: nil, formatDescriptionOut: &description), noErr)
        let format = try XCTUnwrap(description)
        var decoder: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
            decompressionSessionOut: &decoder), noErr)
        let session = try XCTUnwrap(decoder)
        defer { VTDecompressionSessionInvalidate(session) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: packet.data.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: packet.data.count,
            flags: 0, blockBufferOut: &block), noErr)
        let bytes = try XCTUnwrap(block)
        XCTAssertEqual(packet.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bytes, offsetIntoDestination: 0, dataLength: $0.count)
        }, noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: packet.pts, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var length = packet.data.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: bytes, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
            sampleBufferOut: &sample), noErr)
        let decoded = expectation(description: "HEVC decoded")
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(session, sampleBuffer: try XCTUnwrap(sample), flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            XCTAssertEqual(status, noErr)
            XCTAssertEqual(image.map(CVPixelBufferGetWidth), 800)
            XCTAssertEqual(image.map(CVPixelBufferGetHeight), 400)
            decoded.fulfill()
        }, noErr)
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(session), noErr)
        wait(for: [decoded], timeout: 3)
    }
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
