import AppKit
import CoreMedia
import Foundation
import OCUStream
import ScreenCaptureKit

struct StreamCaptureSize: Equatable {
    var width: Int, height: Int
    static func output(_ size: CGSize, maxLongEdge: Int?) -> Self {
        let scale: CGFloat
        if let maxLongEdge { scale = min(1, CGFloat(maxLongEdge) / max(size.width, size.height)) }
        else { scale = 1 }
        // Round down after scaling so the requested long edge is never exceeded.
        return .init(width: max(1, Int((size.width * scale).rounded(.down))),
                     height: max(1, Int((size.height * scale).rounded(.down))))
    }
}

/// The SCStream seam. Implementations deliver all callbacks on the supplied queue.
protocol StreamCaptureDriver: AnyObject {
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, queue: DispatchQueue,
               output: @escaping (SCFrameStatus, CVPixelBuffer?, CMTime, LiveFrameMetadata?) -> Void,
               stopped: @escaping (Error) -> Void, ready: @escaping (Result<CGSize, Error>) -> Void)
    func update(size: StreamCaptureSize, configuration: StreamFrameConfiguration, completion: @escaping (Error?) -> Void)
    func stop()
}

final class SystemStreamCaptureDriver: NSObject, StreamCaptureDriver, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var queue: DispatchQueue!
    private var output: ((SCFrameStatus, CVPixelBuffer?, CMTime, LiveFrameMetadata?) -> Void)?
    private var stopped: ((Error) -> Void)?
    private var cancelled = false
    static func configuration(size: StreamCaptureSize, request: StreamFrameConfiguration) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width; config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.captureResolution = .nominal
        // sRGB values, so the encoded video's BT.709 tags describe them (not the display's P3).
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true; config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = true; config.showsCursor = false; config.capturesAudio = false
        config.queueDepth = 3; config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(request.maxFPS))
        return config
    }
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, queue: DispatchQueue,
               output: @escaping (SCFrameStatus, CVPixelBuffer?, CMTime, LiveFrameMetadata?) -> Void,
               stopped: @escaping (Error) -> Void, ready: @escaping (Result<CGSize, Error>) -> Void) {
        self.queue = queue; self.output = output; self.stopped = stopped
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            queue.async {
                guard !self.cancelled else { return }
                if let error { ready(.failure(error)); return }
                guard let window = content?.windows.first(where: { $0.windowID == windowID }) else {
                    ready(.failure(NSError(domain: "StreamCapture.windowMissing", code: 0))); return
                }
                let size = window.frame.size
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: Self.configuration(size: .output(size, maxLongEdge: configuration.maxLongEdge), request: configuration), delegate: self)
                self.stream = stream
                do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
                catch { ready(.failure(error)); return }
                stream.startCapture { error in
                    queue.async {
                        guard !self.cancelled else { return }
                        if let error { ready(.failure(error)) } else { ready(.success(size)) }
                    }
                }
            }
        }
    }
    func update(size: StreamCaptureSize, configuration: StreamFrameConfiguration, completion: @escaping (Error?) -> Void) {
        stream?.updateConfiguration(Self.configuration(size: size, request: configuration)) { error in
            self.queue.async { if !self.cancelled { completion(error) } }
        }
    }
    func stop() {
        cancelled = true
        guard let stream else { return }
        self.stream = nil
        // Keep the driver/output alive until SC has finished. No wait on output or server.
        stream.stopCapture { [self] _ in try? stream.removeStreamOutput(self, type: .screen) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.cancelled { self.stopped?(error) } }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !cancelled, type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? NSNumber, let status = SCFrameStatus(rawValue: raw.intValue) else { return }
        let metadata: LiveFrameMetadata?
        if let time = attachments[.displayTime] as? NSNumber,
           let rect = attachments[.contentRect] as? NSDictionary,
           let contentRect = CGRect(dictionaryRepresentation: rect),
           let contentScale = attachments[.contentScale] as? NSNumber,
           let scaleFactor = attachments[.scaleFactor] as? NSNumber {
            metadata = .init(displayTime: CaptureClock.seconds(time.uint64Value), contentRect: contentRect,
                             contentScale: CGFloat(contentScale.doubleValue), scaleFactor: CGFloat(scaleFactor.doubleValue))
        } else { metadata = nil }
        output?(status, CMSampleBufferGetImageBuffer(sample), CMSampleBufferGetPresentationTimeStamp(sample), metadata)
    }
}

struct SystemStreamFrameSourceFactory: StreamFrameSourceFactory {
    func supports(_ codec: StreamCodec) -> Bool { codec == .h264 }
    func makeSource() -> StreamFrameSource { StreamCapture() }
}

final class StreamCapture: StreamFrameSource, LiveFrameSource {
    let liveFrames = LiveFrameBuffer()
    static let resizeDebounce: TimeInterval = 0.3
    private let queue = DispatchQueue(label: "OpenComputerUse.stream-capture")
    private let driver: StreamCaptureDriver
    private let permission: () -> Bool
    private let window: (UInt32) -> StreamWindowInfo?
    private let makeEncoder: (@escaping (StreamFrameEvent) -> Void) -> StreamFrameEncoder
    private let now: () -> TimeInterval
    private var encoder: StreamFrameEncoder?
    private var receive: ((StreamFrameEvent) -> Void)?
    private var configuration: StreamFrameConfiguration!
    private var windowID: UInt32 = 0
    private var size: CGSize?
    private var previousOutput: StreamCaptureSize?
    private var pendingSize: (CGSize, TimeInterval)?
    private var state: StreamTargetState?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    // Encoded callbacks use this independent gate; they never wait for capture's queue.
    private let gate = NSLock()
    private var forwarding = false
    private var encoderGeneration: UUID?

    init(driver: StreamCaptureDriver = SystemStreamCaptureDriver(), permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         window: @escaping (UInt32) -> StreamWindowInfo? = { SystemStreamWindowProvider.lookup(id: $0) },
         makeEncoder: @escaping (@escaping (StreamFrameEvent) -> Void) -> StreamFrameEncoder = { StreamEncoder(receive: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver; self.permission = permission; self.window = window; self.makeEncoder = makeEncoder; self.now = now
    }
    func start(windowID: UInt32, configuration: StreamFrameConfiguration, receive: @escaping (StreamFrameEvent) -> Void) throws {
        guard permission() else { throw StreamSourceError.noPermission }
        guard configuration.codec == .h264 else { throw StreamSourceError.codecUnsupported }
        queue.async { [self] in
            guard !self.stopped else { return }
            self.windowID = windowID; self.configuration = configuration; self.receive = receive
            if let info = self.window(windowID) { self.size = CGSize(width: info.frame.width, height: info.frame.height) }
            self.setEncoding(configuration.encode)
            self.driver.start(windowID: windowID, configuration: configuration, queue: self.queue,
                output: { [weak self] status, image, pts, metadata in self?.sample(status, image: image, pts: pts, metadata: metadata) },
                stopped: { [weak self] error in self?.finish(Self.endReason(error)) }, ready: { [weak self] result in
                    guard let self, !self.stopped else { return }
                    switch result {
                    case .success(let size):
                        self.size = size
                        // A configure may have arrived while enumeration/start was pending.
                        if self.configuration != configuration { self.update() }
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now(), repeating: StreamServer.pollInterval)
                        timer.setEventHandler { [weak self] in self?.inspect() }
                        self.timer = timer; timer.resume()
                    case .failure(let error):
                        if self.window(windowID) == nil { self.publish(.closed) }
                        self.finish(Self.endReason(error))
                    }
                })
        }
    }
    func configure(_ configuration: StreamFrameConfiguration) {
        queue.async {
            guard !self.stopped else { return }
            if let size = self.size {
                let old = StreamCaptureSize.output(size, maxLongEdge: self.configuration.maxLongEdge)
                if old != .output(size, maxLongEdge: configuration.maxLongEdge) { self.previousOutput = old }
            }
            self.configuration = configuration; self.setEncoding(configuration.encode); self.update()
        }
    }
    private func setEncoding(_ enabled: Bool) {
        if !enabled {
            gate.withLock { encoderGeneration = nil }
            encoder?.stop(); encoder = nil; return
        }
        guard encoder == nil else { return }
        let generation = UUID()
        gate.withLock { encoderGeneration = generation }
        let receive = self.receive
        encoder = makeEncoder { [weak self] event in
            guard let self else { return }
            let (current, allowed) = self.gate.withLock { (self.encoderGeneration == generation, self.forwarding) }
            guard current else { return }
            if case .ended(let reason) = event {
                self.queue.async { if self.encoderGeneration == generation { self.finish(reason) } }; return
            }
            guard allowed else { return }
            receive?(event)
        }
        encoder?.requestKeyframe()
    }
    func requestKeyframe() { queue.async { self.encoder?.requestKeyframe() } }
    func stop() { queue.async { self.teardown() } }
    private func teardown() {
        guard !stopped else { return }
        stopped = true; gate.lock(); forwarding = false; encoderGeneration = nil; gate.unlock()
        liveFrames.stop()
        timer?.cancel(); timer = nil; receive = nil
        driver.stop(); encoder?.stop(); encoder = nil
    }
    private func finish(_ reason: StreamEndReason) {
        guard !stopped else { return }
        liveFrames.stop(userStopped: reason == .capture_stopped_by_user)
        receive?(.ended(reason)); teardown()
    }
    static func endReason(_ error: Error) -> StreamEndReason {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userStopped.rawValue ? .capture_stopped_by_user : .error
    }
    static func state(status: SCFrameStatus, window: StreamWindowInfo?, previous: StreamTargetState?) -> StreamTargetState? {
        guard let window else { return .closed }
        if window.state == .hidden_from_capture { return .hidden_from_capture }
        if status == .suspended { return window.state == .hidden ? .hidden : .minimized }
        if status == .complete { return .live }
        return previous
    }
    private func publish(_ state: StreamTargetState) {
        guard self.state != state else { return }
        self.state = state
        gate.lock(); forwarding = state == .live; gate.unlock()
        if state != .live { liveFrames.invalidate() }
        receive?(.state(state))
    }
    private func sample(_ status: SCFrameStatus, image: CVPixelBuffer?, pts: CMTime, metadata: LiveFrameMetadata?) {
        guard !stopped else { return }
        let info = window(windowID)
        if let next = Self.state(status: status, window: info, previous: state) { publish(next) }
        guard state == .live else { liveFrames.invalidate(); return }
        if (status == .complete || status == .idle), let metadata, let size {
            let output = StreamCaptureSize.output(size, maxLongEdge: configuration.maxLongEdge)
            let currentSize = info.map { CGSize(width: $0.frame.width, height: $0.frame.height) }
            if let image, let previousOutput,
               (CVPixelBufferGetWidth(image) != output.width || CVPixelBufferGetHeight(image) != output.height),
               CVPixelBufferGetWidth(image) == previousOutput.width, CVPixelBufferGetHeight(image) == previousOutput.height {
                // The old configuration can still have queued surfaces during resize.
                liveFrames.invalidate(); return
            }
            if status == .idle, let previousOutput,
               metadata.contentRect == CGRect(x: 0, y: 0, width: previousOutput.width, height: previousOutput.height),
               previousOutput != output { liveFrames.invalidate(); return }
            let wrongSize = image.map { CVPixelBufferGetWidth($0) != output.width || CVPixelBufferGetHeight($0) != output.height } ?? false
            if currentSize == size && (wrongSize || metadata.contentRect != CGRect(x: 0, y: 0, width: output.width, height: output.height)) {
                receive?(.contentChanged); teardown(); return
            }
            if currentSize == size, status == .complete { previousOutput = nil }
        } else if status == .complete, image != nil {
            // A complete surface without identity/geometry metadata cannot be checked.
            receive?(.contentChanged); teardown(); return
        }
        if let info, let size, CGSize(width: info.frame.width, height: info.frame.height) == size {
            liveFrames.receive(status: status, image: image, metadata: metadata)
        } else { liveFrames.invalidate() }
        guard status == .complete, let image else { return }
        if let encoder {
            do { try encoder.encode(StreamFrameImages.encoderInput(image, maxLongEdge: configuration.encoderMaxLongEdge), pts: pts) }
            catch { finish(.error) }
        }
    }
    private func inspect() {
        guard !stopped else { return }
        guard let info = window(windowID) else { publish(.closed); finish(.error); return }
        if info.state == .hidden_from_capture || info.state == .hidden { publish(info.state) }
        considerResize(CGSize(width: info.frame.width, height: info.frame.height), at: now())
    }
    // Time is injected for headless debounce checks; the production poll uses monotonic uptime.
    func considerResize(_ next: CGSize, at time: TimeInterval) {
        guard next.width > 0, next.height > 0 else { return }
        if next == size { pendingSize = nil; return }
        if pendingSize?.0 != next { pendingSize = (next, time); return }
        if let pendingSize, time - pendingSize.1 >= Self.resizeDebounce {
            if let size { previousOutput = .output(size, maxLongEdge: configuration.maxLongEdge) }
            size = next; self.pendingSize = nil; update()
        }
    }
    private func update() {
        guard let size, let configuration else { return }
        liveFrames.invalidate()
        driver.update(size: .output(size, maxLongEdge: configuration.maxLongEdge), configuration: configuration) { [weak self] error in
            if let self, let error { self.finish(Self.endReason(error)) }
        }
    }
}

/// Token creation belongs to the host, which may start after the helper.
/// Retry on this private queue; a broken stream socket cannot block native IPC.
final class StreamServerLifecycle {
    static let retryInterval: TimeInterval = 1
    private let queue = DispatchQueue(label: "OpenComputerUse.stream-lifecycle")
    private let startServer: () throws -> Void
    private let stopServer: () -> Void
    private let log: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var reasons = Set<String>()
    init(start: @escaping () throws -> Void, stop: @escaping () -> Void,
         log: @escaping (String) -> Void = { fputs("Stream server: \($0)\n", stderr) }) {
        startServer = start; stopServer = stop; self.log = log
    }
    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.retryInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do { try self.startServer(); self.timer?.cancel(); self.timer = nil }
                catch { let reason = String(describing: error); if self.reasons.insert(reason).inserted { self.log(reason) } }
            }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil; stopServer() } }
}
