import AppKit
import CoreImage
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

// Host-clock seconds, the same timebase as SCStreamFrameInfo.displayTime.
enum CaptureClock {
    static func seconds(_ ticks: UInt64) -> TimeInterval {
        CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))
    }
    static func now() -> TimeInterval { seconds(mach_absolute_time()) }
}

enum CaptureMode: String, Codable { case live, screenshots }

/// One helper owns the setting. A rename publishes a complete, owner-only file.
final class CaptureModeStore {
    private struct FileValue: Codable { var mode: CaptureMode }
    let url: URL
    private let lock = NSLock()
    private var value: CaptureMode
    var mode: CaptureMode { lock.withLock { value } }

    init(runtime: URL, log: (String) -> Void = { fputs("\($0)\n", stderr) }) {
        url = runtime.appendingPathComponent("capture-mode.json")
        var st = stat()
        if lstat(url.path, &st) != 0 && errno == ENOENT { value = .live }
        else if st.st_mode & S_IFMT == S_IFREG,
                let data = try? Data(contentsOf: url),
                let file = try? JSONDecoder().decode(FileValue.self, from: data) { value = file.mode }
        else {
            value = .screenshots
            log("Malformed capture-mode.json; using screenshots only.")
        }
    }
    func set(_ mode: CaptureMode) throws {
        try lock.withLock {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".capture-mode-\(UUID().uuidString)")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.write(contentsOf: JSONEncoder().encode(FileValue(mode: mode)))
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            value = mode
        }
    }
}

struct LiveFrameMetadata {
    var displayTime: TimeInterval
    var contentRect: CGRect
    var contentScale: CGFloat
    var scaleFactor: CGFloat
}
struct LiveFrame {
    var image: CVPixelBuffer
    var metadata: LiveFrameMetadata
    var size: CGSize { CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) }
    func matches(_ size: CGSize) -> Bool {
        metadata.contentScale == 1 && self.size == size && metadata.contentRect == CGRect(origin: .zero, size: size)
    }
    func cgImage() -> CGImage? {
        let image = CIImage(cvPixelBuffer: image)
        return StreamFrameImages.context.createCGImage(image, from: image.extent)
    }
}

enum LiveCaptureError: String, Error { case capture_stopped_by_user }

/// Only a complete surface is held. An idle sample advances its freshness, not its pixels.
/// The condition never blocks the source/server queues; only a screenshot's capture queue waits.
final class LiveFrameBuffer {
    static let freshnessWait: TimeInterval = 0.250 // D6
    private let condition = NSCondition()
    private let now: () -> TimeInterval
    private let wait: (NSCondition, TimeInterval) -> Void
    private var held: LiveFrame?
    private var sampleTime: TimeInterval?
    private var receivedAt: TimeInterval?
    private var stopped = false
    private var userStopped = false

    init(now: @escaping () -> TimeInterval = CaptureClock.now,
         wait: @escaping (NSCondition, TimeInterval) -> Void = { condition, remaining in
             _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
         }) { self.now = now; self.wait = wait }

    func receive(status: SCFrameStatus, image: CVPixelBuffer?, metadata: LiveFrameMetadata?) {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { return }
        if status == .complete, let image, let metadata {
            held = .init(image: image, metadata: metadata)
        } else if status == .idle, let metadata, let previous = held {
            if metadata.contentRect != previous.metadata.contentRect || metadata.contentScale != previous.metadata.contentScale { held = nil }
        } else { held = nil }
        if (status == .complete || status == .idle), let metadata, held != nil {
            sampleTime = metadata.displayTime; receivedAt = now()
        } else { sampleTime = nil; receivedAt = nil }
        condition.broadcast()
    }
    var captureStoppedByUser: Bool {
        condition.lock(); defer { condition.unlock() }; return userStopped
    }
    func invalidate() {
        condition.lock(); held = nil; sampleTime = nil; receivedAt = nil
        condition.broadcast(); condition.unlock()
    }
    func stop(userStopped: Bool = false) {
        condition.lock(); stopped = true; self.userStopped = self.userStopped || userStopped
        held = nil; condition.broadcast(); condition.unlock()
    }
    func frame(after request: TimeInterval, size: CGSize) throws -> LiveFrame? {
        condition.lock(); defer { condition.unlock() }
        let deadline = request + Self.freshnessWait
        while true {
            if userStopped { throw LiveCaptureError.capture_stopped_by_user }
            if stopped { return nil }
            if let sampleTime, sampleTime > request, let receivedAt, receivedAt <= deadline,
               let held { return held.matches(size) ? held : nil }
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            wait(condition, remaining)
        }
    }
}
protocol LiveFrameSource: AnyObject { var liveFrames: LiveFrameBuffer { get } }

/// Shared by live-frame and one-off images: same compositor and JPEG properties.
enum ApplicationSurfaceImage {
    static func draw(_ image: CGImage, in rect: NSRect) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    static func metadata(width: Int, height: Int, bounds: CGRect, windowCount: Int, source: String) -> [String: Any] {
        ["success": true, "capture_source": source, "data": ["observations": [[
            "coordinates": ["image_size_pixels": ["width": width, "height": height],
                            "logical_bounds": [[bounds.minX, bounds.minY], [bounds.width, bounds.height]]],
            "window_count": windowCount,
        ]]]]
    }
    static func encode(_ bitmap: NSBitmapImageRep, isPNG: Bool) -> Data? {
        bitmap.representation(using: isPNG ? .png : .jpeg, properties: isPNG ? [:] : [.compressionFactor: 0.86])
    }
}

/// A viewer's size request applies to encoded video; an agent still needs the
/// shared SCStream's full point-resolution surface for screenshot parity.
enum StreamFrameImages {
    static let context = CIContext()
    static func encoderInput(_ image: CVPixelBuffer, maxLongEdge: Int?) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let output = StreamCaptureSize.output(CGSize(width: width, height: height), maxLongEdge: maxLongEdge)
        guard output.width != width || output.height != height else { return image }
        var scaled: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, output.width, output.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &scaled)
        guard status == kCVReturnSuccess, let scaled else {
            throw NSError(domain: "StreamCapture.encoderSize", code: Int(status))
        }
        let transform = CGAffineTransform(scaleX: CGFloat(output.width) / CGFloat(width), y: CGFloat(output.height) / CGFloat(height))
        context.render(CIImage(cvPixelBuffer: image).transformed(by: transform), to: scaled)
        return scaled
    }
}
