import AppKit
import AVFoundation
import OCUStream

/// This panel cannot take the keyboard, even when its controls are clicked.
final class PiPWindow: NSPanel, NSWindowDelegate {
    let canvas = PiPView()
    var onClose: (() -> Void)?
    var onPositionChanged: (() -> Void)?
    private var targetSize = CGSize.zero

    init(name: String, slot: Int) {
        super.init(contentRect: CGRect(origin: .zero, size: PiPGeometry.size(windowSize: .zero)),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = name
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        hasShadow = true; animationBehavior = .none
        contentView = canvas; delegate = self
        canvas.setIdentity(name: name, slot: slot)
        canvas.onClose = { [weak self] in self?.close() }
        canvas.onDragEnded = { [weak self] in self?.onPositionChanged?() }
        updateSize(.zero)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateSize(_ size: CGSize) {
        targetSize = size
        contentMinSize = PiPGeometry.size(width: PiPGeometry.widthRange.lowerBound, windowSize: size)
        contentMaxSize = PiPGeometry.size(width: PiPGeometry.widthRange.upperBound, windowSize: size)
        let next = PiPGeometry.size(width: frame.width, windowSize: size)
        let top = frame.maxY
        setFrame(CGRect(x: frame.minX, y: top - next.height, width: next.width, height: next.height), display: true)
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PiPGeometry.size(width: frameSize.width, windowSize: targetSize)
    }
    func windowDidEndLiveResize(_ notification: Notification) { onPositionChanged?() }
    func windowWillClose(_ notification: Notification) { canvas.shutdown(); onClose?() }
}

/// Video, cursor and local controls only. No input is forwarded to the target.
final class PiPView: NSView {
    let video = AVSampleBufferDisplayLayer()
    let cursorView = AgentCursorView()
    private let material = NSVisualEffectView()
    private let dim = NSView()
    private let message = NSTextField(labelWithString: "")
    private let permission = NSButton(title: "Permissions…", target: nil, action: nil)
    private let toolbar = NSVisualEffectView()
    private let appIcon = NSImageView()
    private let appName = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let showButton = NSButton(title: "Show Window", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var format: CMVideoFormatDescription?
    private var failureObserver: NSObjectProtocol?
    private var latestCursor: StreamCursor?
    private var windowSize = CGSize.zero
    private var name = ""
    private var slot = 0
    private var waitingForKeyframe = true
    private var switching = false
    var state: PiPState = .noTarget { didSet { applyState() } }
    var onClose: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onKeyframe: (() -> Void)?
    var onDragEnded: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true; layer?.borderWidth = 1
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
        toolbar.material = .hudWindow; toolbar.blendingMode = .withinWindow; toolbar.state = .active
        addSubview(toolbar)
        toolbar.addSubview(appIcon); toolbar.addSubview(appName); toolbar.addSubview(closeButton)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appName.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        appName.lineBreakMode = .byTruncatingTail
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close preview")
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closePreview)
        closeButton.setAccessibilityLabel("Close preview")
        showButton.isEnabled = false
        showButton.target = self; showButton.action = #selector(showWindow); showButton.bezelStyle = .rounded
        addSubview(showButton)
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode, object: video, queue: .main
        ) { [weak self] _ in self?.decodeFailed() }
        applyState(); setHover(false)
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) } }

    func setIdentity(name: String, slot: Int) {
        self.name = name; self.slot = slot
        let palette = AgentCursorView.palette
        layer?.borderColor = palette[slot % palette.count].withAlphaComponent(0.55).cgColor
        updateCursor()
    }
    func setTarget(_ target: StreamTarget, changed: Bool) {
        windowSize = CGSize(width: target.frame.width, height: target.frame.height)
        appName.stringValue = target.app_name ?? ""
        appIcon.image = NSRunningApplication(processIdentifier: target.pid)?.icon
        showButton.isEnabled = target.pid > 0
        if changed {
            switching = true; latestCursor = nil; cursorView.reset()
            resetVideo()
        }
        updateCursor()
    }
    func setCursor(_ cursor: StreamCursor) { latestCursor = cursor; updateCursor() }
    func clearTarget() {
        latestCursor = nil; cursorView.reset()
        appName.stringValue = ""; appIcon.image = nil; showButton.isEnabled = false
    }
    func resetVideo() { video.flushAndRemoveImage(); format = nil; waitingForKeyframe = true }
    func shutdown() { resetVideo(); cursorView.reset() }

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
        cursorView.frame = bounds; dim.frame = bounds
        let hasButton = state == .noPermission
        message.frame = CGRect(x: 12, y: bounds.midY - (hasButton ? 26 : 10), width: bounds.width - 24, height: 22)
        permission.frame = CGRect(x: bounds.midX - 65, y: bounds.midY + 3, width: 130, height: 28)
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 40)
        // NSVisualEffectView uses bottom-left coordinates.
        appIcon.frame = CGRect(x: 12, y: 10, width: 20, height: 20)
        appName.frame = CGRect(x: 40, y: 12, width: bounds.width - 84, height: 18)
        closeButton.frame = CGRect(x: bounds.width - 34, y: 8, width: 24, height: 24)
        showButton.frame = CGRect(x: bounds.width - 122, y: bounds.height - 38, width: 110, height: 28)
        updateCursor()
    }
    private func updateCursor() {
        guard let c = latestCursor,
              let point = PiPGeometry.viewPoint(window: CGPoint(x: c.x, y: c.y), windowSize: windowSize, viewSize: bounds.size) else { return }
        let end = c.to_x.flatMap { x in c.to_y.flatMap { y in
            PiPGeometry.viewPoint(window: CGPoint(x: x, y: y), windowSize: windowSize, viewSize: bounds.size)
        } }
        cursorView.show(AgentCursor(client: c.agent, name: name, slot: slot, pid: 0, window_id: 0,
                                    x: point.x, y: point.y, kind: c.kind, to_x: end.map { Double($0.x) }, to_y: end.map { Double($0.y) },
                                    at: c.at, busy: c.busy), windowOrigin: .zero)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    func setHover(_ hovering: Bool) {
        toolbar.isHidden = !hovering; showButton.isHidden = !hovering
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onShowWindow?() }
        else { window?.performDrag(with: event); onDragEnded?() }
    }
    @objc private func closePreview() { onClose?() }
    @objc private func showWindow() { onShowWindow?() }
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
                guard let sets = sample.header.format, !sets.sps.isEmpty, !sets.pps.isEmpty else { throw PiPDecodeError.invalidFormat }
                let data = (sets.sps + sets.pps).map { $0 as NSData }
                let pointers = data.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
                let sizes = data.map(\.length)
                var description: CMVideoFormatDescription?
                let result = withExtendedLifetime(data) { CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: data.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description) }
                guard result == noErr, let description else { throw PiPDecodeError.invalidFormat }
                format = description; waitingForKeyframe = false
            }
            guard let format else { throw PiPDecodeError.invalidFormat }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: sample.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: sample.data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
                let block else { throw PiPDecodeError.invalidSample }
            let copied = sample.data.withUnsafeBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.data.count)
            }
            guard copied == kCMBlockBufferNoErr else { throw PiPDecodeError.invalidSample }
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTime(seconds: sample.header.pts, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
            var size = sample.data.count
            var buffer: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
                let buffer else { throw PiPDecodeError.invalidSample }
            // No playback clock: this is a live, low-latency preview.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) else {
                throw PiPDecodeError.invalidSample
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
private enum PiPDecodeError: Error { case invalidFormat, invalidSample }
