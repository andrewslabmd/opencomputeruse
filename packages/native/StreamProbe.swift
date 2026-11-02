import AppKit
import CoreMedia
import CoreImage
import ScreenCaptureKit
import VideoToolbox
import Darwin

// Phase 0 only. One bounded request owns all streams, including the three-stream
// budget case, because helper file requests otherwise run on a serial queue.
struct StreamProbeRequest: Decodable {
    let windowID: CGWindowID
    let filter: String
    let windowIDs: [CGWindowID]?
    let concurrentWindowIDs: [CGWindowID]?
    let includeChildWindows: Bool
    let fps: Int32
    let durationMs: Int
    let encode: Bool?
    let sampleDirectory: String?
    let sampleCount: Int?
    let screenshotRequestTimesMs: [Int]?
}

struct StreamProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func probeError(_ error: Error) -> [String: Any] {
    let e = error as NSError
    return ["domain": e.domain, "code": e.code, "message": e.localizedDescription]
}

private func probeRect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
private func probeWindowList() -> [[String: Any]] {
    // No titles: also compare the granted helper's inventory with the external
    // read-only observer when system menu-bar windows aren't exposed there.
    (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).map { w in
        ["id": w[kCGWindowNumber as String] ?? 0, "pid": w[kCGWindowOwnerPID as String] ?? 0,
         "owner": w[kCGWindowOwnerName as String] ?? "", "layer": w[kCGWindowLayer as String] ?? 0,
         "bounds": w[kCGWindowBounds as String] ?? [:], "onScreen": w[kCGWindowIsOnscreen as String] ?? false]
    }
}
private func probeSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
}

final class StreamProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private let request: StreamProbeRequest
    private let windowID: CGWindowID
    private let queue = DispatchQueue(label: "OpenComputerUse.phase0.samples")
    private let encoderLock = NSLock()
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var frames: [[String: Any]] = [], counts: [String: Int] = [:]
    private var stopErrors: [[String: Any]] = [], encoderErrors: [Int32] = []
    private var encoderBytes = 0, keyframes = 0, encodedFrames = 0, emptyEncoderCallbacks = 0
    private var startTicks: UInt64 = 0
    private var firstFrameMs: Double?
    private var saved: [[String: Any]] = []
    private var latestImage: CVPixelBuffer?
    private var pendingShots: [(index: Int, ticks: UInt64)] = []
    private var shots: [[String: Any]] = []
    private let context = CIContext()
    private var configurationInfo: [String: Any] = [:]
    private var windowsDuring: [[String: Any]] = []

    private init(_ request: StreamProbeRequest, windowID: CGWindowID) {
        self.request = request; self.windowID = windowID
    }

    static func run(_ request: StreamProbeRequest, checkCancellation: () throws -> Void) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw StreamProbeFailure("Screen Recording permission is required; probe never requests it") }
        guard request.durationMs > 0, request.fps > 0, ["window", "display"].contains(request.filter),
              (request.sampleCount ?? 0) >= 0,
              (request.screenshotRequestTimesMs ?? []).allSatisfy({ $0 >= 0 && $0 < request.durationMs }) else {
            throw StreamProbeFailure("Invalid probe duration, rate, filter or sample parameters")
        }
        if let path = request.sampleDirectory {
            guard (path as NSString).isAbsolutePath else { throw StreamProbeFailure("Sample directory must be absolute") }
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let windowsBefore = probeWindowList()
        let ready = DispatchSemaphore(value: 0)
        var content: SCShareableContent?, listingError: Error?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { c, e in
            content = c; listingError = e; ready.signal()
        }
        guard ready.wait(timeout: .now() + .milliseconds(request.durationMs)) == .success else { throw StreamProbeFailure("Shareable-content listing exceeded request duration") }
        if let e = listingError { throw e }
        guard let content else { throw StreamProbeFailure("No shareable content") }
        let probes = ([request.windowID] + (request.concurrentWindowIDs ?? [])).map { StreamProbe(request, windowID: $0) }
        do {
            for probe in probes { try checkCancellation(); try probe.start(content) }
            let end = Date(timeIntervalSinceNow: Double(request.durationMs) / 1000)
            while Date() < end { try checkCancellation(); Thread.sleep(forTimeInterval: min(0.05, end.timeIntervalSinceNow)) }
        } catch {
            for probe in probes { probe.stop() }
            throw error
        }
        for probe in probes { probe.stop() }
        return ["streams": probes.map { $0.result() }, "shareableOnScreenWindowsOnly": false,
                "windowsBefore": windowsBefore, "windowsAfter": probeWindowList()]
    }

    private func start(_ content: SCShareableContent) throws {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw StreamProbeFailure("Target window \(windowID) absent from shareable content") }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width.rounded(.up)); config.height = Int(window.frame.height.rounded(.up))
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.captureResolution = .nominal
        config.scalesToFit = true; config.ignoreShadowsSingleWindow = true
        config.showsCursor = false; config.capturesAudio = false; config.queueDepth = 3
        config.includeChildWindows = request.includeChildWindows
        config.minimumFrameInterval = CMTime(value: 1, timescale: request.fps)
        let filter: SCContentFilter
        if request.filter == "window" { filter = SCContentFilter(desktopIndependentWindow: window) }
        else {
            let ids = Set(request.windowIDs ?? [windowID])
            let windows = content.windows.filter { ids.contains($0.windowID) }
            guard ids == Set(windows.map(\.windowID)) else { throw StreamProbeFailure("A requested display-filter window was absent from shareable content") }
            guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { throw StreamProbeFailure("No display intersects the target") }
            let bounds = windows.reduce(window.frame) { $0.union($1.frame) }
            config.sourceRect = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(bounds.width.rounded(.up)); config.height = Int(bounds.height.rounded(.up))
            filter = SCContentFilter(display: display, including: windows)
        }
        configurationInfo = ["width": config.width, "height": config.height, "windowFrame": probeRect(window.frame), "filter": request.filter,
            "windowIDs": request.windowIDs ?? [windowID], "includeChildWindows": request.includeChildWindows, "fps": request.fps,
            "pixelFormat": "BGRA", "captureResolution": "nominal", "scalesToFit": true, "ignoreShadowsSingleWindow": true,
            "showsCursor": false, "capturesAudio": false, "queueDepth": 3]
        if request.encode == true { try makeEncoder(width: config.width, height: config.height) }
        let stream = SCStream(filter: filter, configuration: config, delegate: self); self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        startTicks = mach_absolute_time()
        let started = DispatchSemaphore(value: 0); var startError: Error?
        stream.startCapture { e in startError = e; started.signal() }
        guard started.wait(timeout: .now() + .milliseconds(request.durationMs)) == .success else { throw StreamProbeFailure("startCapture exceeded request duration") }
        if let e = startError { throw e }
        for (index, offset) in (request.screenshotRequestTimesMs ?? []).enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(offset)) { self.pendingShots.append((index, mach_absolute_time())) }
        }
    }

    private func makeEncoder(width: Int, height: Int) throws {
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                Unmanaged<StreamProbe>.fromOpaque(ref).takeUnretainedValue().encoded(status, sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
        guard status == noErr, let encoder else { throw StreamProbeFailure("VTCompressionSessionCreate: \(status)") }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!), (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)] {
            let status = VTSessionSetProperty(encoder, key: key, value: value)
            guard status == noErr else { throw StreamProbeFailure("VTSessionSetProperty \(key): \(status)") }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(encoder)
        guard prepared == noErr else { throw StreamProbeFailure("VTCompressionSessionPrepareToEncodeFrames: \(prepared)") }
    }

    private func encoded(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        encoderLock.lock(); defer { encoderLock.unlock() }
        guard status == noErr else { encoderErrors.append(status); return }
        guard let sample else { emptyEncoderCallbacks += 1; return }
        encodedFrames += 1; encoderBytes += CMSampleBufferGetTotalSampleSize(sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true { keyframes += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.stopErrors.append(probeError(error)) } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrival = mach_absolute_time()
        if frames.isEmpty { windowsDuring = probeWindowList() }
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let raw = (attachments[.status] as? NSNumber)?.intValue ?? -1
        let status = [0: "complete", 1: "idle", 2: "blank", 3: "suspended", 4: "started", 5: "stopped"][raw] ?? "unknown"
        let display = (attachments[.displayTime] as? NSNumber)?.uint64Value
        var frame: [String: Any] = ["status": status, "statusRaw": raw, "arrivalTime": arrival, "arrivalMs": probeSeconds(arrival - startTicks) * 1000]
        frame["displayTime"] = display ?? NSNull() as Any
        for (key, name) in [(SCStreamFrameInfo.contentRect, "contentRect"), (.screenRect, "screenRect")] {
            if let dict = attachments[key] as? [String: Any], let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) { frame[name] = probeRect(rect) }
            else { frame[name] = NSNull() }
        }
        for (key, name) in [(SCStreamFrameInfo.contentScale, "contentScale"), (.scaleFactor, "scaleFactor")] { frame[name] = attachments[key] ?? NSNull() }
        frame["dirtyRectCount"] = (attachments[.dirtyRects] as? [Any])?.count ?? 0
        let image = CMSampleBufferGetImageBuffer(sample)
        frame["hasImageBuffer"] = image != nil
        if let image { frame["imageSize"] = [CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)] }
        frames.append(frame); counts[status, default: 0] += 1
        if status == "complete", let image {
            latestImage = image
            if firstFrameMs == nil { firstFrameMs = probeSeconds(arrival - startTicks) * 1000 }
            if let encoder {
                let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
                if result != noErr { encoderLock.lock(); encoderErrors.append(result); encoderLock.unlock() }
            }
        }
        if let display, ["complete", "idle"].contains(status), latestImage != nil {
            let eligible = pendingShots.filter { display > $0.ticks }
            for shot in eligible {
                shots.append(["index": shot.index, "requestTime": shot.ticks, "sampleDisplayTime": display,
                    "latencyMs": probeSeconds(arrival - shot.ticks) * 1000, "status": status, "reused": status == "idle"])
            }
            pendingShots.removeAll { display > $0.ticks }
        }
        let count = request.sampleCount ?? 0
        if let directory = request.sampleDirectory, saved.count < count,
           probeSeconds(arrival - startTicks) * 1000 >= Double(saved.count * request.durationMs) / Double(max(count, 1)),
           let image = image ?? (status == "idle" ? latestImage : nil) {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("\(windowID)-\(saved.count)-\(status).png")
            if let cg = context.createCGImage(CIImage(cvPixelBuffer: image), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))),
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                do { try data.write(to: path); saved.append(["path": path.path, "frameIndex": frames.count - 1, "status": status]) }
                catch { saved.append(["error": error.localizedDescription]) }
            }
        }
    }

    private func stop() {
        if let stream {
            let stopped = DispatchSemaphore(value: 0)
            stream.stopCapture { error in
                if let error { self.queue.async { self.stopErrors.append(probeError(error)) } }
                stopped.signal()
            }
            if stopped.wait(timeout: .now() + .milliseconds(request.durationMs)) != .success {
                queue.async { self.stopErrors.append(["domain": "StreamProbe", "code": -1, "message": "stopCapture exceeded request duration"]) }
            }
            try? stream.removeStreamOutput(self, type: .screen)
            self.stream = nil
        }
        queue.sync {
            if let encoder { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(encoder); self.encoder = nil }
            latestImage = nil
        }
    }

    private func result() -> [String: Any] {
        queue.sync {
            encoderLock.lock(); defer { encoderLock.unlock() }
            return ["windowID": windowID, "configuration": configurationInfo, "frames": frames, "countsByStatus": counts, "windowsDuring": windowsDuring,
                "firstFrameLatencyMs": firstFrameMs.map { $0 as Any } ?? NSNull(), "stopErrors": stopErrors, "sampleFrames": saved,
                "screenshotTimings": shots, "unansweredScreenshotRequests": pendingShots.map { $0.index },
                "encoder": ["enabled": request.encode ?? false, "outputBytes": encoderBytes, "keyframes": keyframes,
                    "frames": encodedFrames, "emptyCallbacks": emptyEncoderCallbacks, "errors": encoderErrors, "lowLatencyRateControl": request.encode ?? false]]
        }
    }
}
