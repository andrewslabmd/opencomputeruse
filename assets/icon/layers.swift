// Writes the layer files of OpenComputerUse.icon (Icon Composer): two ripple
// circles and a pointer whose tip sits at their center, as a click. Layers
// are plain masks; color, glass and shadow come from icon.json.
// The pointer is Phosphor's "navigation-arrow" (fill weight, Phosphor Icons,
// MIT license; see THIRD_PARTY_NOTICES.md), placed on the 1024 canvas.
// Run: swift assets/icon/layers.swift
import AppKit

let size = 1024.0
let tip = 369.5                                // ripple center = pointer tip, top-left origin
let span = 500.0                               // pointer width and height on the canvas
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/icon/OpenComputerUse.icon/Assets")

// Phosphor navigation-arrow-fill, 256-unit grid; its shape spans 40.9...248.
let phosphorPath = "M248,121.58a15.76,15.76,0,0,1-11.29,15l-.2.06-78,21.84-21.84,78-.06.2a15.77,15.77,0,0,1-15,11.29h-.3a15.77,15.77,0,0,1-15.07-10.67L41,61.41a1,1,0,0,1-.05-.16A16,16,0,0,1,61.25,40.9l.16.05,175.92,65.26A15.78,15.78,0,0,1,248,121.58Z"
let scale = span / (248 - 40.9)
let offset = tip - 40.9 * scale

func ripple(_ name: String, radius: Double) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.setFillColor(CGColor(srgbRed: 0, green: 0.56, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: tip - radius, y: size - tip - radius, width: radius * 2, height: radius * 2))
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try ripple("Ripple1.png", radius: 215)
try ripple("Ripple2.png", radius: 118)
let svg = String(format: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><path fill=\"#ffffff\" transform=\"translate(%.2f %.2f) scale(%.4f)\" d=\"%@\"/></svg>\n", offset, offset, scale, phosphorPath)
try svg.write(to: directory.appendingPathComponent("Pointer.svg"), atomically: true, encoding: .utf8)
