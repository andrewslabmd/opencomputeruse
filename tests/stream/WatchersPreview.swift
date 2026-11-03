#if WATCHERS_PREVIEW
import AppKit
import SwiftUI

/// Compiled separately. No OCU launch, capture, input, or visible window.
@main
struct WatchersPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let row = Form {
            Section {
                MenuAgentRow(name: "Claude Code", activity: "Thinking in Finder",
                             watchers: ["Open Computer Use", "botfactory"], hasApp: true,
                             watch: {}, disconnect: {}) {
                    Circle().fill(.blue).frame(width: 24 * 0.45, height: 24 * 0.45).frame(width: 24, height: 24)
                }
            } header: { Text("Agents") }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 340, height: 180)
        let host = NSHostingView(rootView: row)
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 180)
        // An unordered offscreen window supplies native control and material rendering.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewError.bitmap }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.bitmap }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try png.write(to: output)
        print(output.path)
    }
    enum PreviewError: Error { case bitmap }
}
#endif
