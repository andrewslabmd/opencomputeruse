import Foundation

public enum StreamCodec: String, Codable, Equatable { case h264, hevc }
public enum StreamTargetState: String, Codable, Equatable {
    case live, minimized, hidden, closed, idle, hidden_from_capture, stopped, no_permission
}
public enum StreamEndReason: String, Codable, Equatable {
    case released, disconnected, stopped, paused, unsubscribed, capture_stopped_by_user, error
}
public enum StreamErrorCode: String, Codable, Equatable {
    case unauthorized, unsupported_version, unknown_agent, paused, no_permission, codec_unsupported
}

public struct StreamHello: Codable, Equatable {
    public var version: Int
    public var token: String?
    public var client: String?
    public init(version: Int = 1, token: String? = nil, client: String? = nil) {
        self.version = version; self.token = token; self.client = client
    }
}
public struct StreamAgent: Codable, Equatable {
    public var agent: String
    public var name: String
    public var color_slot: Int
    public var app_name: String?
    public var busy: Bool
    public var state: StreamTargetState
    public var watchers: [String]
    public init(agent: String, name: String, color_slot: Int, app_name: String?, busy: Bool, state: StreamTargetState, watchers: [String] = []) {
        self.agent = agent; self.name = name; self.color_slot = color_slot
        self.app_name = app_name; self.busy = busy; self.state = state; self.watchers = watchers
    }
    private enum CodingKeys: String, CodingKey { case agent, name, color_slot, app_name, busy, state, watchers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(agent: try c.decode(String.self, forKey: .agent), name: try c.decode(String.self, forKey: .name),
                  color_slot: try c.decode(Int.self, forKey: .color_slot), app_name: try c.decodeIfPresent(String.self, forKey: .app_name),
                  busy: try c.decode(Bool.self, forKey: .busy), state: try c.decode(StreamTargetState.self, forKey: .state),
                  watchers: try c.decodeIfPresent([String].self, forKey: .watchers) ?? [])
    }
}
public struct StreamAgentsMessage: Codable, Equatable {
    public var agents: [StreamAgent]
    public init(agents: [StreamAgent]) { self.agents = agents }
}
public struct StreamSubscription: Codable, Equatable {
    public var agent: String
    public var max_fps: Int
    public var max_long_edge: Int?
    public var codec: StreamCodec
    public init(agent: String, max_fps: Int = 15, max_long_edge: Int? = nil, codec: StreamCodec = .h264) {
        self.agent = agent; self.max_fps = max_fps; self.max_long_edge = max_long_edge; self.codec = codec
    }
    private enum CodingKeys: String, CodingKey { case agent, max_fps, max_long_edge, codec }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(agent: try c.decode(String.self, forKey: .agent),
                  max_fps: try c.decodeIfPresent(Int.self, forKey: .max_fps) ?? 15,
                  max_long_edge: try c.decodeIfPresent(Int.self, forKey: .max_long_edge),
                  codec: try c.decodeIfPresent(StreamCodec.self, forKey: .codec) ?? .h264)
        guard (1...30).contains(max_fps), max_long_edge.map({ $0 > 0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid subscription size or rate"))
        }
    }
}
public struct StreamAgentRequest: Codable, Equatable {
    public var agent: String
    public init(agent: String) { self.agent = agent }
}
/// Window Server coordinates: top-left origin, logical points. Encodes as [x,y,w,h].
public struct StreamRect: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self)
        width = try c.decode(Double.self); height = try c.decode(Double.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected four frame components") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(width); try c.encode(height)
    }
}
public struct StreamTarget: Codable, Equatable {
    public var agent: String
    public var pid: Int32
    public var app_name: String?
    public var window_id: UInt32
    public var frame: StreamRect
    public var scale: Double
    public var state: StreamTargetState
    public init(agent: String, pid: Int32, app_name: String?, window_id: UInt32, frame: StreamRect, scale: Double, state: StreamTargetState) {
        self.agent = agent; self.pid = pid; self.app_name = app_name; self.window_id = window_id
        self.frame = frame; self.scale = scale; self.state = state
    }
}
public struct StreamCursor: Codable, Equatable {
    public var agent: String
    public var x: Double, y: Double
    public var to_x: Double?, to_y: Double?
    public var kind: String
    public var busy: Bool
    public var at: Double
    public init(agent: String, x: Double, y: Double, to_x: Double? = nil, to_y: Double? = nil, kind: String, busy: Bool, at: Double) {
        self.agent = agent; self.x = x; self.y = y; self.to_x = to_x; self.to_y = to_y
        self.kind = kind; self.busy = busy; self.at = at
    }
}
public struct StreamEnd: Codable, Equatable {
    public var agent: String
    public var reason: StreamEndReason
    public init(agent: String, reason: StreamEndReason) { self.agent = agent; self.reason = reason }
}
public struct StreamFailure: Codable, Equatable {
    public var code: StreamErrorCode
    public var agent: String?
    public var supported: [Int]?
    public init(code: StreamErrorCode, agent: String? = nil, supported: [Int]? = nil) {
        self.code = code; self.agent = agent; self.supported = supported
    }
}
public struct StreamVideoFormat: Codable, Equatable {
    // Data's Codable representation is base64, including each parameter-set element.
    public var vps: [Data]?
    public var sps: [Data]
    public var pps: [Data]
    public init(vps: [Data]? = nil, sps: [Data], pps: [Data]) { self.vps = vps; self.sps = sps; self.pps = pps }
}
public struct StreamVideoHeader: Codable, Equatable {
    public var agent: String
    public var pts: Double
    public var keyframe: Bool
    public var codec: StreamCodec
    public var format: StreamVideoFormat?
    public init(agent: String, pts: Double, keyframe: Bool, codec: StreamCodec, format: StreamVideoFormat? = nil) {
        self.agent = agent; self.pts = pts; self.keyframe = keyframe; self.codec = codec; self.format = format
    }
}
public struct StreamVideo: Equatable {
    public var header: StreamVideoHeader
    public var data: Data
    public init(header: StreamVideoHeader, data: Data) { self.header = header; self.data = data }
}

/// The same flattened JSON objects are shared by the app and helper.
public enum StreamControl: Codable, Equatable {
    case hello(StreamHello), list, agents(StreamAgentsMessage), subscribe(StreamSubscription)
    case unsubscribe(StreamAgentRequest), keyframe(StreamAgentRequest)
    case target(StreamTarget), cursor(StreamCursor), end(StreamEnd), error(StreamFailure)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try StreamHello(from: decoder))
        case "list": self = .list
        case "agents": self = .agents(try StreamAgentsMessage(from: decoder))
        case "subscribe": self = .subscribe(try StreamSubscription(from: decoder))
        case "unsubscribe": self = .unsubscribe(try StreamAgentRequest(from: decoder))
        case "keyframe": self = .keyframe(try StreamAgentRequest(from: decoder))
        case "target": self = .target(try StreamTarget(from: decoder))
        case "cursor": self = .cursor(try StreamCursor(from: decoder))
        case "end": self = .end(try StreamEnd(from: decoder))
        case "error": self = .error(try StreamFailure(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown stream message")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let type: String
        switch self {
        case .hello(let p): type = "hello"; try p.encode(to: encoder)
        case .list: type = "list"
        case .agents(let p): type = "agents"; try p.encode(to: encoder)
        case .subscribe(let p): type = "subscribe"; try p.encode(to: encoder)
        case .unsubscribe(let p): type = "unsubscribe"; try p.encode(to: encoder)
        case .keyframe(let p): type = "keyframe"; try p.encode(to: encoder)
        case .target(let p): type = "target"; try p.encode(to: encoder)
        case .cursor(let p): type = "cursor"; try p.encode(to: encoder)
        case .end(let p): type = "end"; try p.encode(to: encoder)
        case .error(let p): type = "error"; try p.encode(to: encoder)
        }
        try c.encode(type, forKey: .type)
    }
}
