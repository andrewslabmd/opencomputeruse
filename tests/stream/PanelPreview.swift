#if PANEL_PREVIEW
import AppKit
import SwiftUI
import AVFoundation
import VideoToolbox
import CoreImage
import OCUStream

/// Manual renderer of the real MenuPanel, with synthetic window content encoded
/// to H.264 and decoded again. Never orders a window, connects to a host,
/// captures an app, launches OCU, or forwards input.
@main
struct PanelPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = NSImage(contentsOfFile: "assets/icon/compiled/OpenComputerUse.icns")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sample = try SampleFrame()
        for count in [1, 2] { try render(count: count, sample: sample, output: output) }
    }
    @MainActor private static func render(count: Int, sample: SampleFrame, output: URL) throws {
        let model = HostModel(startServices: false)
        model.health = .ready; model.accessibility = true; model.screenRecording = true
        model.agents = (0..<count).map {
            Agent(id: "preview-\($0)", name: $0 == 0 ? "PiP demo agent" : "Claude Code", app: "OCU Stream Fixture",
                  appPID: NSRunningApplication.current.processIdentifier, slot: $0, busy: $0 == 1)
        }
        for agent in model.agents {
            let preview = model.panelPreviews.preview(for: agent)
            let target = StreamTarget(agent: agent.id, pid: NSRunningApplication.current.processIdentifier,
                app_name: agent.app, window_id: 1, frame: .init(x: 0, y: 0, width: 960, height: 600), scale: 1, state: .live)
            preview.windowSize = CGSize(width: 960, height: 600)
            preview.canvas.setTarget(target, changed: true)
            preview.canvas.state = .live
            preview.canvas.onKeyframe = { fatalError("Synthetic H.264 sample failed to decode") }
            preview.canvas.enqueue(try sample.streamVideo(agent: agent.id))
            // AVSampleBufferDisplayLayer's remote video surface is omitted by
            // cacheDisplay. Supply the independently decoded pixels to that
            // same layer for this offscreen snapshot (as in the old PiP renderer).
            preview.canvas.video.contents = sample.decoded
            preview.canvas.video.contentsGravity = .resizeAspect
            preview.canvas.setCursor(.init(agent: agent.id, x: 560, y: 270,
                kind: agent.busy ? "type" : "move", busy: agent.busy, at: 1))
        }
        let host = NSHostingView(rootView: MenuPanel(model: model))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        // Let SwiftUI finish measuring representable views in the unordered window.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        for agent in model.agents {
            let canvas = model.panelPreviews.preview(for: agent).canvas
            canvas.layoutSubtreeIfNeeded()
            guard canvas.bounds.width > 0, canvas.bounds.height <= 220 else { throw PreviewError.layout }
            print("\(agent.id): preview \(canvas.bounds.size), cursor canvas \(canvas.cursorView.bounds.size)")
        }
        CATransaction.flush()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.bitmap }
        let path = output.appendingPathComponent(count == 1 ? "one-agent.png" : "two-agents.png")
        try png.write(to: path)
        print("\(path.path): \(Int(size.width * 2))×\(Int(size.height * 2)), 2×")
        for agent in model.agents { model.panelPreviews.preview(for: agent).canvas.shutdown() }
        window.contentView = nil
    }
    enum PreviewError: Error { case bitmap, layout }
}

private final class SampleFrame {
    var encoded: CMSampleBuffer?
    var pixels: CVPixelBuffer?
    let decoded: CGImage
    init() throws {
        // Existing PiP fixture dimensions, with table rows like the approved mockup.
        var buffer: CVPixelBuffer?
        try Self.check(CVPixelBufferCreate(nil, 960, 600, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer))
        let source = buffer!
        CVPixelBufferLockBaseAddress(source, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(source), width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(source), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 960, height: 600).fill()
        NSColor.darkGray.setFill(); CGRect(x: 0, y: 574, width: 960, height: 26).fill()
        ("OCU Stream Fixture" as NSString).draw(at: CGPoint(x: 18, y: 580), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        for row in 0..<27 {
            let y = 554 - row * 20
            (row.isMultiple(of: 2) ? NSColor(white: 0.92, alpha: 1) : NSColor.white).setFill()
            CGRect(x: 0, y: y, width: 960, height: 20).fill()
            ("Row \(27-row)   Project activity — background capture measurement   0123456789" as NSString)
                .draw(at: CGPoint(x: 12, y: y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
            NSColor.systemBlue.setFill()
            CGRect(x: 690, y: y + 4, width: 12 + (row % 9) * 10, height: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(source, [])
        // A callback box is used because self is not fully initialized yet.
        let box = SampleBox()
        let ref = Unmanaged.passUnretained(box).toOpaque()
        var encoder: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(allocator: nil, width: 960, height: 600, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                if status == noErr, let ref, let sample { Unmanaged<SampleBox>.fromOpaque(ref).takeUnretainedValue().sample = sample }
            }, refcon: ref, compressionSessionOut: &encoder))
        defer { VTCompressionSessionInvalidate(encoder!) }
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try Self.check(VTCompressionSessionEncodeFrame(encoder!, imageBuffer: source, presentationTimeStamp: .zero,
            duration: .invalid, frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil))
        try Self.check(VTCompressionSessionCompleteFrames(encoder!, untilPresentationTimeStamp: .invalid))
        guard let compressed = box.sample, let format = CMSampleBufferGetFormatDescription(compressed) else { throw SampleError.missing }
        var decoder: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            if status == noErr, let ref { Unmanaged<SampleBox>.fromOpaque(ref).takeUnretainedValue().pixels = image }
        }, decompressionOutputRefCon: ref)
        try Self.check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decoder))
        defer { VTDecompressionSessionInvalidate(decoder!) }
        try Self.check(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: compressed, flags: [], frameRefcon: nil, infoFlagsOut: nil))
        try Self.check(VTDecompressionSessionWaitForAsynchronousFrames(decoder!))
        guard let pixels = box.pixels else { throw SampleError.missing }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { throw SampleError.missing }
        self.encoded = compressed; self.pixels = pixels; self.decoded = cg
    }
    func streamVideo(agent: String) throws -> StreamVideo {
        let sample = encoded!, format = CMSampleBufferGetFormatDescription(sample)!
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            try Self.check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil))
            sets.append(Data(bytes: pointer!, count: size))
        }
        let block = CMSampleBufferGetDataBuffer(sample)!
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        try Self.check(status)
        return StreamVideo(header: .init(agent: agent, pts: 0, keyframe: true, codec: .h264,
            format: .init(sps: [sets[0]], pps: [sets[1]])), data: data)
    }
    static func check(_ status: OSStatus) throws { if status != noErr { throw SampleError.status(status) } }
    enum SampleError: Error { case status(OSStatus), missing }
    private final class SampleBox { var sample: CMSampleBuffer?; var pixels: CVPixelBuffer? }
}
#endif
