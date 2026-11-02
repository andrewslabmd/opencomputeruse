import AppKit
import SwiftUI

// Compile with the actual CaptureMode and PreferencesSection declarations.
// Renders offscreen without initializing HostModel or opening a window.
@main
struct PreferencesPreview {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in CaptureMode.allCases {
            let view = NSHostingView(rootView: Form {
                PreferencesSection(showCursors: .constant(true), captureMode: .constant(mode), launchAtLogin: .constant(false))
            }.formStyle(.grouped))
            view.frame = CGRect(x: 0, y: 0, width: 580, height: 240)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PreviewError.bitmap }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.bitmap }
            let name = mode == .live ? "preferences.png" : "preferences-screenshots.png"
            try png.write(to: directory.appendingPathComponent(name))
            print(directory.appendingPathComponent(name).path)
        }
    }
    enum PreviewError: Error { case bitmap }
}
