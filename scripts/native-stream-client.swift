#if STREAM_NATIVE_CLIENT
import AppKit
import CoreImage
import CoreMedia
import Darwin
import Foundation
import VideoToolbox

private let outputLock = NSLock()
private func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data + Data([10]))
}
private func checkStatus(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: "SocketDecoder", code: Int(status)) }
}

/// Shared native harness consumer, derived from tests/native/StreamSocketClient.swift.
/// Each agent owns a separate VideoToolbox session; every packet and decoded frame is reported.
/// A real socket/VideoToolbox consumer. Compiled only by the opt-in native harness.
private final class SocketDecoder {
    var fd: Int32 = -1
    var agent = ""
    var measureEveryFrame = false
    var decoders: [String: SocketDecoder] = [:]
    init(agent: String, directory: URL, measureEveryFrame: Bool) { self.agent = agent; self.directory = directory; self.measureEveryFrame = measureEveryFrame }
    var session: VTDecompressionSession?
    var format: CMVideoFormatDescription?
    let lock = NSLock()
    var labels: [String] = []
    let directory: URL
    let context = CIContext()
    init(runtime: String, directory: String) throws {
        self.directory = URL(fileURLWithPath: directory)
        self.measureEveryFrame = CommandLine.arguments.contains("--measure-every-frame")
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array((runtime + "/stream.sock").utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "socketPath", code: 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let status = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        try send(["type": "hello", "version": 1, "client": "Native stream decoder", "token": try String(contentsOfFile: runtime + "/host-token", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)])
        try send(["type": "list"])
    }
    func send(_ object: [String: Any]) throws {
        var body = Data([1]); body.append(try JSONSerialization.data(withJSONObject: object))
        var length = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(body)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw NSError(domain: "write", code: Int(errno)) }; offset += n
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw NSError(domain: "read", code: Int(errno)) }; offset += n
            }
        }
        return data
    }
    func word(_ data: Data, _ offset: Int = 0) -> Int { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
    func run() throws {
        while true {
            let n = word(try read(4))
            guard n > 0, n <= 8 * 1024 * 1024 else { throw NSError(domain: "frameLength", code: n) }
            let body = try read(n)
            if body[0] == 1 {
                let control = try JSONSerialization.jsonObject(with: body.dropFirst()) as! [String: Any]
                emit(control)
            } else {
                guard body[0] == 2, body.count >= 5 else { throw NSError(domain: "messageKind", code: 1) }
                let h = word(body, 1)
                guard h > 0, 5 + h <= body.count else { throw NSError(domain: "videoHeader", code: 1) }
                let header = try JSONSerialization.jsonObject(with: body[5..<(5 + h)]) as! [String: Any]
                guard let agent = header["agent"] as? String, h > 0, 5 + h <= body.count else { throw NSError(domain: "videoHeader", code: 1) }
                lock.lock()
                let decoder: SocketDecoder
                if let existing = decoders[agent] { decoder = existing }
                else { decoder = SocketDecoder(agent: agent, directory: directory, measureEveryFrame: measureEveryFrame); decoders[agent] = decoder }
                lock.unlock()
                emit(["type": "packet", "agent": agent, "pts": header["pts"]!, "keyframe": header["keyframe"] ?? false])
                try decoder.decode(header: header, data: Data(body[(5 + h)...]))
            }
        }
    }
    func decode(header: [String: Any], data: Data) throws {
        if let f = header["format"] as? [String: Any] {
            let sets = ((f["sps"] as? [String] ?? []) + (f["pps"] as? [String] ?? [])).map { Data(base64Encoded: $0)! }
            let pointers = sets.map { d -> UnsafeMutablePointer<UInt8> in let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count); d.copyBytes(to: p, count: d.count); return p }
            defer { pointers.forEach { $0.deallocate() } }
            var newFormat: CMFormatDescription?
            try checkStatus(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                parameterSetPointers: pointers.map { UnsafePointer($0) }, parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat))
            if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: newFormat!) {
                if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
                format = newFormat
                var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, pts, _ in
                    guard let ref else { return }
                    let client = Unmanaged<SocketDecoder>.fromOpaque(ref).takeUnretainedValue()
                    if status != noErr { emit(["type": "decode_error", "agent": client.agent, "status": status]); return }
                    if let image { client.decoded(image, pts: pts) }
                }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                try checkStatus(VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat!, decoderSpecification: nil,
                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                    outputCallback: &callback, decompressionSessionOut: &session))
            }
            emit(["type": "keyframe", "agent": agent, "pts": header["pts"]!, "format": f])
        }
        guard let format, let session else { throw NSError(domain: "missingFormat", code: 1) }
        var block: CMBlockBuffer?
        try checkStatus(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block))
        try checkStatus(data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) })
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: header["pts"] as! Double, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?, size = data.count
        try checkStatus(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        try checkStatus(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], frameRefcon: nil, infoFlagsOut: nil))
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    func decoded(_ image: CVPixelBuffer, pts: CMTime) {
        lock.lock(); let label = labels.isEmpty ? nil : labels.removeFirst(); lock.unlock()
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let ci = CIImage(cvPixelBuffer: image), colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var middle = [UInt8](repeating: 0, count: 4)
        context.render(ci, toBitmap: &middle, rowBytes: 4, bounds: CGRect(x: width / 2, y: height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        if measureEveryFrame { emit(["type": "frame", "agent": agent, "pts": CMTimeGetSeconds(pts), "width": width, "height": height, "centerRGB": Array(middle.prefix(3))]) }
        guard let label else { return }
        let cg = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)!
        let path = directory.appendingPathComponent(label + ".png")
        try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: path)
        if measureEveryFrame {
            emit(["type": "png", "agent": agent, "label": label, "path": path.path, "width": width, "height": height,
                  "pts": CMTimeGetSeconds(pts), "centerRGB": Array(middle.prefix(3))])
            return
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(ci, toBitmap: &pixels, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        let center = (height / 2 * width + width / 2) * 4
        var palette = ["magenta": 0, "yellow": 0, "orange": 0]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i+1]), Int(pixels[i+2])]
            for (name, expected) in [("magenta", [255,0,255]), ("yellow", [255,255,0]), ("orange", [255,128,0])] {
                if zip(rgb, expected).allSatisfy({ abs($0 - $1) <= 16 }) { palette[name]! += 1 }
            }
        }
        emit(["type": "png", "agent": agent, "label": label, "path": path.path, "width": width, "height": height,
              "pts": CMTimeGetSeconds(pts), "centerRGB": Array(pixels[center..<(center+3)]), "palettePixels": palette])
    }
}

@main private struct NativeStreamClient {
    static func main() throws {
        if CommandLine.arguments[1] == "--watch" {
            func observe() {
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                emit(["type": "watch", "at": Date().timeIntervalSince1970, "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                      "windows": windows.map { ["id": $0[kCGWindowNumber as String] ?? 0, "pid": $0[kCGWindowOwnerPID as String] ?? 0, "layer": $0[kCGWindowLayer as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] }])
            }
            observe(); Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { observe() } }; RunLoop.main.run()
            return
        }
        let client = try SocketDecoder(runtime: CommandLine.arguments[1], directory: CommandLine.arguments[2])
        DispatchQueue.global().async {
            do { try client.run() } catch { emit(["type": "client_error", "error": String(describing: error)]); exit(1) }
        }
        while let line = readLine() {
            let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if let label = command["snapshot"] as? String {
                client.lock.lock()
                let decoder: SocketDecoder?
                if let agent = command["agent"] as? String { decoder = client.decoders[agent] }
                else { decoder = client.decoders.values.first }
                client.lock.unlock()
                guard let decoder else { throw NSError(domain: "snapshotBeforeFirstFrame", code: 1) }
                decoder.lock.lock(); decoder.labels.append(label); decoder.lock.unlock()
            }
            else { try client.send(command) }
        }
    }
}
#endif
