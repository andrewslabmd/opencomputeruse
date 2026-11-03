import AppKit
import AVFoundation
import SwiftUI
import OCUStream

/// Inline video and cursor only. No input is forwarded to the target.
final class InlinePreviewView: NSView {
    let video = AVSampleBufferDisplayLayer()
    let cursorView = AgentCursorView()
    private let material = NSVisualEffectView()
    private let dim = NSView()
    private let message = NSTextField(labelWithString: "")
    private let permission = NSButton(title: "Permissions…", target: nil, action: nil)
    private var format: CMVideoFormatDescription?
    private var failureObserver: NSObjectProtocol?
    private var latestCursor: StreamCursor?
    private var windowSize = CGSize.zero
    private var name = ""
    private var slot = 0
    private var waitingForKeyframe = true
    private var switching = false
    var state: PiPState = .noTarget { didSet { applyState() } }
    var onPermissions: (() -> Void)?
    var onKeyframe: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8; layer?.masksToBounds = true; layer?.borderWidth = 1
        material.material = .hudWindow; material.blendingMode = .withinWindow; material.state = .active
        addSubview(material)
        material.wantsLayer = true; material.layer?.addSublayer(video)
        video.videoGravity = .resizeAspect
        cursorView.showsBorder = false
        addSubview(cursorView)
        dim.wantsLayer = true; dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        addSubview(dim)
        message.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        message.textColor = .labelColor; message.alignment = .center
        addSubview(message)
        permission.target = self; permission.action = #selector(openPermissions); permission.bezelStyle = .rounded
        addSubview(permission)
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode, object: video, queue: .main
        ) { [weak self] _ in self?.decodeFailed() }
        applyState()
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) } }

    func setIdentity(name: String, slot: Int) {
        self.name = name; self.slot = slot
        let palette = AgentCursorView.palette
        layer?.borderColor = palette[slot % palette.count].cgColor
        updateCursor()
    }
    func setTarget(_ target: StreamTarget, changed: Bool) {
        windowSize = CGSize(width: target.frame.width, height: target.frame.height)
        if changed {
            switching = true; latestCursor = nil; cursorView.reset()
            resetVideo()
        }
        updateCursor()
    }
    func setCursor(_ cursor: StreamCursor) { latestCursor = cursor; updateCursor() }
    func clearTarget() {
        latestCursor = nil; cursorView.reset()
    }
    func resetVideo() { video.flushAndRemoveImage(); format = nil; waitingForKeyframe = true }
    func shutdown() { resetVideo(); clearTarget() }

    private func applyState() {
        video.isHidden = !state.keepsLastFrame
        cursorView.isHidden = state != .live
        dim.isHidden = !state.dimsLastFrame
        message.stringValue = state.text ?? ""; message.isHidden = state.text == nil
        message.textColor = state.dimsLastFrame ? .white : .labelColor
        permission.isHidden = state != .noPermission
        if !state.keepsLastFrame { resetVideo() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        material.frame = bounds; video.frame = material.bounds
        cursorView.frame = bounds
        // Scale the entire NSView coordinate space: pointer, tag, ripple and
        // bounce all retain their on-screen proportions at 60%.
        cursorView.bounds = CGRect(origin: .zero, size: InlinePreviewGeometry.cursorCanvas(viewSize: bounds.size))
        dim.frame = bounds
        let hasButton = state == .noPermission
        message.frame = CGRect(x: 12, y: bounds.midY - (hasButton ? 26 : 10), width: bounds.width - 24, height: 22)
        permission.frame = CGRect(x: bounds.midX - 65, y: bounds.midY + 3, width: 130, height: 28)
        updateCursor()
    }
    private func updateCursor() {
        guard let c = latestCursor,
              let point = InlinePreviewGeometry.cursorPoint(window: CGPoint(x: c.x, y: c.y), windowSize: windowSize, viewSize: bounds.size) else { return }
        let end = c.to_x.flatMap { x in c.to_y.flatMap { y in
            InlinePreviewGeometry.cursorPoint(window: CGPoint(x: x, y: y), windowSize: windowSize, viewSize: bounds.size)
        } }
        cursorView.show(AgentCursor(client: c.agent, name: name, slot: slot, pid: 0, window_id: 0,
                                    x: point.x, y: point.y, kind: c.kind, to_x: end.map { Double($0.x) }, to_y: end.map { Double($0.y) },
                                    at: c.at, busy: c.busy), windowOrigin: .zero)
    }
    @objc private func openPermissions() { onPermissions?() }

    private func decodeFailed() {
        resetVideo(); onKeyframe?()
    }
    func enqueue(_ sample: StreamVideo) {
        guard state == .live else { return }
        guard sample.header.codec == .h264 else { decodeFailed(); return }
        if video.status == .failed { decodeFailed() }
        if waitingForKeyframe && !sample.header.keyframe { return }
        do {
            if sample.header.keyframe {
                guard let sets = sample.header.format, !sets.sps.isEmpty, !sets.pps.isEmpty else { throw PreviewDecodeError.invalidFormat }
                let data = (sets.sps + sets.pps).map { $0 as NSData }
                let pointers = data.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
                let sizes = data.map(\.length)
                var description: CMVideoFormatDescription?
                let result = withExtendedLifetime(data) { CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: data.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description) }
                guard result == noErr, let description else { throw PreviewDecodeError.invalidFormat }
                format = description; waitingForKeyframe = false
            }
            guard let format else { throw PreviewDecodeError.invalidFormat }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: sample.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: sample.data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
                let block else { throw PreviewDecodeError.invalidSample }
            let copied = sample.data.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.data.count)
            }
            guard copied == kCMBlockBufferNoErr else { throw PreviewDecodeError.invalidSample }
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTime(seconds: sample.header.pts, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
            var size = sample.data.count
            var buffer: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
                let buffer else { throw PreviewDecodeError.invalidSample }
            // No playback clock: this is a live, low-latency preview.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) else {
                throw PreviewDecodeError.invalidSample
            }
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            video.enqueue(buffer)
            if switching {
                switching = false
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
                video.add(fade, forKey: "targetChange")
            }
        } catch { decodeFailed() }
    }
}
private enum PreviewDecodeError: Error { case invalidFormat, invalidSample }

/// Each row owns its render state; the controller owns the shared connection.
@MainActor
final class AgentPreview: ObservableObject {
    let canvas = InlinePreviewView()
    @Published var windowSize = CGSize.zero
    var target: StreamTarget?
    var end: StreamEndReason?
    var failure: StreamErrorCode?
}

struct InlinePreview: NSViewRepresentable {
    let preview: AgentPreview
    func makeNSView(context: Context) -> InlinePreviewView { preview.canvas }
    func updateNSView(_ view: InlinePreviewView, context: Context) {}
}

struct AgentPreviewRow: View {
    @ObservedObject var preview: AgentPreview
    var body: some View {
        PreviewLayout(windowSize: preview.windowSize) {
            InlinePreview(preview: preview)
        }
        .accessibilityLabel("Live agent preview")
    }
}

private struct PreviewLayout: Layout {
    let windowSize: CGSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        InlinePreviewGeometry.size(width: proposal.width ?? 0, windowSize: windowSize)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(bounds.size))
    }
}
