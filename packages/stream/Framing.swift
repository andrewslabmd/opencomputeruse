import Foundation

public enum StreamMessage: Equatable { case control(StreamControl), video(StreamVideo) }
public enum StreamFramingError: Error, Equatable { case invalidLength, oversized, unknownKind, invalidVideoHeader }

public enum StreamFraming {
    public static let version = 1
    public static let maximumLength = 8 * 1024 * 1024
    public static func encode(_ message: StreamMessage) throws -> Data {
        var body = Data()
        switch message {
        case .control(let control):
            body.append(1); body.append(try JSONEncoder().encode(control))
        case .video(let video):
            guard video.header.keyframe || video.header.format == nil else { throw StreamFramingError.invalidVideoHeader }
            let header = try JSONEncoder().encode(video.header)
            guard header.count + 5 + video.data.count <= maximumLength else { throw StreamFramingError.oversized }
            body.append(2); body.appendBE(UInt32(header.count)); body.append(header); body.append(video.data)
        }
        guard body.count <= maximumLength else { throw StreamFramingError.oversized }
        var result = Data(); result.appendBE(UInt32(body.count)); result.append(body)
        return result
    }
}

/// Buffers at most one incomplete frame. A bad frame permanently fails the decoder.
public struct StreamDecoder {
    private var buffer = Data()
    private var expected: Int?
    private var failed = false
    public init() {}
    public mutating func append(_ data: Data) throws -> [StreamMessage] {
        guard !failed else { throw StreamFramingError.invalidLength }
        do {
            var messages: [StreamMessage] = []
            var offset = data.startIndex
            while offset < data.endIndex {
                let needed = (expected ?? 4) - buffer.count
                let count = min(needed, data.endIndex - offset)
                buffer.append(data[offset..<(offset + count)]); offset += count
                if expected == nil, buffer.count == 4 {
                    let length = Int(buffer.beUInt32(at: 0))
                    guard length > 0 else { throw StreamFramingError.invalidLength }
                    guard length <= StreamFraming.maximumLength else { throw StreamFramingError.oversized }
                    expected = length; buffer.removeAll(keepingCapacity: true)
                }
                if let length = expected, buffer.count == length {
                    switch buffer[0] {
                    case 1: messages.append(.control(try JSONDecoder().decode(StreamControl.self, from: buffer.dropFirst())))
                    case 2:
                        guard length >= 5 else { throw StreamFramingError.invalidVideoHeader }
                        let h = Int(buffer.beUInt32(at: 1))
                        guard h > 0, h <= length - 5 else { throw StreamFramingError.invalidVideoHeader }
                        let header = try JSONDecoder().decode(StreamVideoHeader.self, from: buffer[5..<(5 + h)])
                        guard header.keyframe || header.format == nil else { throw StreamFramingError.invalidVideoHeader }
                        messages.append(.video(.init(header: header, data: Data(buffer[(5 + h)...]))))
                    default: throw StreamFramingError.unknownKind
                    }
                    expected = nil; buffer.removeAll(keepingCapacity: true)
                }
            }
            return messages
        } catch { failed = true; buffer.removeAll(); throw error }
    }
}
private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 255)); append(UInt8((value >> 16) & 255))
        append(UInt8((value >> 8) & 255)); append(UInt8(value & 255))
    }
    func beUInt32(at i: Int) -> UInt32 {
        (UInt32(self[i]) << 24) | (UInt32(self[i+1]) << 16) | (UInt32(self[i+2]) << 8) | UInt32(self[i+3])
    }
}
