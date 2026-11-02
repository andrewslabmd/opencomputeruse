import CoreMedia
import Foundation
import OCUStream
import VideoToolbox

protocol StreamFrameEncoder: AnyObject {
    func encode(_ image: CVPixelBuffer, pts: CMTime) throws
    func requestKeyframe()
    func stop()
}

struct StreamEncodingError: Error { let status: OSStatus }

/// Submissions and invalidation belong to this queue, never the native queue.
/// VT's output callback may wait on the server, so stop never waits for it.
final class StreamEncoder: StreamFrameEncoder {
    private let queue = DispatchQueue(label: "OpenComputerUse.stream-encoder")
    private var session: VTCompressionSession?
    private var size: (Int, Int)?
    private var requestedKeyframe: UInt64 = 0
    private var deliveredKeyframe: UInt64 = 0
    private var stopped = false
    private let receive: (StreamFrameEvent) -> Void

    init(receive: @escaping (StreamFrameEvent) -> Void) { self.receive = receive }

    func requestKeyframe() { queue.async { self.requestedKeyframe += 1 } }
    func stop() {
        queue.async {
            self.stopped = true
            self.invalidate()
        }
    }
    private func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; size = nil
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    func encode(_ image: CVPixelBuffer, pts: CMTime) throws {
        try queue.sync {
            guard !stopped else { return }
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            if size?.0 != width || size?.1 != height {
                invalidate()
                try create(width: width, height: height)
                requestedKeyframe += 1
            }
            guard let session else { return }
            let generation = requestedKeyframe
            let properties = generation > deliveredKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [self] status, _, sample in
                    guard status == noErr else { receive(.ended(.error)); return }
                    // Low-latency default rate control can drop a frame, including
                    // a forced IDR. A successful submission is not an acknowledgement.
                    guard let sample else { return }
                    do {
                        let packet = try StreamEncoder.packet(sample)
                        if packet.keyframe {
                            queue.async { self.deliveredKeyframe = max(self.deliveredKeyframe, generation) }
                        }
                        receive(.sample(packet))
                    } catch { receive(.ended(.error)) }
                }
            guard result == noErr else { throw StreamEncodingError(status: result) }
        }
    }
    private func create(width: Int, height: Int) throws {
        let result = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard result == noErr, let session else { throw StreamEncodingError(status: result) }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!),
                             (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!),
                             (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] as [(CFString, CFTypeRef)] {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { invalidate(); throw StreamEncodingError(status: status) }
        }
        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { invalidate(); throw StreamEncodingError(status: status) }
        size = (width, height)
    }
    static func packet(_ sample: CMSampleBuffer) throws -> StreamEncodedSample {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        var format: StreamVideoFormat?
        if keyframe {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw StreamEncodingError(status: kCMFormatDescriptionError_InvalidParameter) }
            var sets: [Data] = []
            var count = 0
            var length: Int32 = 0
            var pointer: UnsafePointer<UInt8>?, bytes = 0
            var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &bytes, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
            guard status == noErr, length == 4 else { throw StreamEncodingError(status: status) }
            for index in 0..<count {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &bytes, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer else { throw StreamEncodingError(status: status) }
                sets.append(Data(bytes: pointer, count: bytes))
            }
            format = .init(sps: sets.filter { $0.first.map { $0 & 0x1f == 7 } ?? false },
                           pps: sets.filter { $0.first.map { $0 & 0x1f == 8 } ?? false })
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw StreamEncodingError(status: kCMBlockBufferBadPointerParameterErr) }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { throw StreamEncodingError(status: status) }
        return .init(pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), keyframe: keyframe, format: format, data: data)
    }
}
