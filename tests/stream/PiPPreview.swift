#if PIP_PREVIEW
import AppKit
import OCUStream

/// Manually compiled offscreen renderer. Not part of the normal test run and
/// never orders a window on screen, starts OCU, captures a screen, or sends input.
@main
struct PiPPreview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let target = StreamTarget(agent: "preview", pid: NSRunningApplication.current.processIdentifier, app_name: "Sample App", window_id: 1,
            frame: .init(x: 0, y: 0, width: 960, height: 600), scale: 1, state: .live)
        for state in PiPState.allCases where state != .disconnected {
            try render(state: state, target: target, output: output, typing: false, hover: false)
        }
        try render(state: .live, target: target, output: output, typing: true, hover: false)
        try render(state: .live, target: target, output: output, typing: false, hover: true)
        try render(state: .live, target: target, output: output, typing: true, hover: false, width: 240)
        try render(state: .live, target: target, output: output, typing: true, hover: false, width: 720)
    }
    static func render(state: PiPState, target: StreamTarget, output: URL, typing: Bool, hover: Bool,
                       width: CGFloat = 360) throws {
        let size = PiPGeometry.size(width: width, windowSize: CGSize(width: 960, height: 600))
        let view = PiPView(frame: CGRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        view.setIdentity(name: "Claude Code", slot: 2)
        view.setTarget(target, changed: true)
        view.state = state
        view.setCursor(.init(agent: "preview", x: 390, y: 250, kind: typing ? "type" : "move", busy: true, at: 1))
        view.setHover(hover)
        view.layoutSubtreeIfNeeded()
        // A synthetic sample-window bitmap for visual layout only, never a
        // product fallback or a capture of a personal app.
        if state.keepsLastFrame {
            let image = NSImage(size: CGSize(width: 960, height: 600), flipped: false) { rect in
                NSColor.textBackgroundColor.setFill(); rect.fill()
                NSColor.windowBackgroundColor.setFill(); CGRect(x: 0, y: 548, width: 960, height: 52).fill()
                let font = NSFont.systemFont(ofSize: 22, weight: .medium)
                ("Sample window" as NSString).draw(at: CGPoint(x: 28, y: 562), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                for row in 0..<6 {
                    NSColor.separatorColor.setFill()
                    CGRect(x: 32, y: 460 - row * 64, width: row % 2 == 0 ? 640 : 480, height: 12).fill()
                }
                return true
            }
            view.video.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            view.video.contentsGravity = .resizeAspect
        }
        CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PreviewError.bitmap }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.bitmap }
        let name = "\(state)\(typing ? "-typing" : "")\(hover ? "-hover" : "")-\(Int(width)).png"
        try png.write(to: output.appendingPathComponent(name))
        print(name)
        view.shutdown()
    }
    enum PreviewError: Error { case bitmap }
}
#endif
