import XCTest
import OCUStream

final class StreamProtocolTests: XCTestCase {
    private let format = StreamVideoFormat(sps: [Data([0x67, 0x64])], pps: [Data([0x68])])
    func testAllTypedControlMessagesRoundTripAndWireShape() throws {
        let controls: [StreamControl] = [
            .hello(.init(token: "test", client: "PiP")), .hello(.init()), .list,
            .agents(.init(agents: [.init(agent: "a", name: "Agent", color_slot: 2, app_name: "Fixture", busy: true, state: .live)])),
            .subscribe(.init(agent: "a", max_fps: 30, max_long_edge: 720, codec: .hevc)),
            .unsubscribe(.init(agent: "a")), .keyframe(.init(agent: "a")),
            .target(.init(agent: "a", pid: 1, app_name: "Fixture", window_id: 42,
                          frame: .init(x: -10, y: 20, width: 300, height: 200), scale: 1, state: .minimized)),
            .cursor(.init(agent: "a", x: 1, y: 2, to_x: 30, to_y: 40, kind: "drag", busy: false, at: 123)),
            .end(.init(agent: "a", reason: .unsubscribed)), .error(.init(code: .unsupported_version, supported: [1]))]
        for control in controls {
            var decoder = StreamDecoder()
            XCTAssertEqual(try decoder.append(StreamFraming.encode(.control(control))), [.control(control)])
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(control)) as! [String: Any]
            XCTAssertNotNil(json["type"])
        }
        let targetJSON = try JSONEncoder().encode(controls[7])
        let target = try JSONSerialization.jsonObject(with: targetJSON) as! [String: Any]
        XCTAssertEqual(target["frame"] as? [Double], [-10, 20, 300, 200])
        for state in [StreamTargetState.live, .minimized, .closed, .idle, .hidden_from_capture, .stopped, .no_permission] {
            XCTAssertEqual(try JSONDecoder().decode(StreamTargetState.self, from: JSONEncoder().encode(state)), state)
        }
        for reason in [StreamEndReason.released, .disconnected, .stopped, .paused, .unsubscribed, .capture_stopped_by_user, .error] {
            XCTAssertEqual(try JSONDecoder().decode(StreamEndReason.self, from: JSONEncoder().encode(reason)), reason)
        }
    }
    func testVideoAVCCAndParameterSetsRoundTripWithPartialReads() throws {
        let sample = Data([0,0,0,3,0x65,0x01,0x02])
        let video = StreamMessage.video(.init(header: .init(agent: "a", pts: 1.25, keyframe: true, codec: .h264, format: format), data: sample))
        let data = try StreamFraming.encode(video)
        XCTAssertEqual(data[4], 2)
        var decoder = StreamDecoder(), decoded: [StreamMessage] = []
        for byte in data { decoded += try decoder.append(Data([byte])) }
        XCTAssertEqual(decoded, [video])
        let hevc = StreamMessage.video(.init(header: .init(agent: "b", pts: 0, keyframe: true, codec: .hevc,
            format: .init(vps: [Data([1])], sps: [Data([2])], pps: [Data([3])])), data: sample))
        XCTAssertEqual(try decoder.append(StreamFraming.encode(hevc)), [hevc])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(format)) as! [String: Any]
        XCTAssertEqual(json["sps"] as? [String], ["Z2Q="])
    }
    func testTwoFramesInOneReadAndSplitLength() throws {
        let a = StreamMessage.control(.list), b = StreamMessage.control(.hello(.init()))
        let bytes = try StreamFraming.encode(a) + StreamFraming.encode(b)
        var decoder = StreamDecoder()
        XCTAssertEqual(try decoder.append(bytes.prefix(2)), [])
        XCTAssertEqual(try decoder.append(bytes.dropFirst(2)), [a,b])
        XCTAssertEqual(Array(bytes.prefix(4)), [0,0,0,16]) // kind + {"type":"list"}
    }
    func testEightMiBBoundaryAndMalformedFrames() throws {
        let header = StreamVideoHeader(agent: "a", pts: 0, keyframe: false, codec: .h264)
        let overhead = 5 + (try JSONEncoder().encode(header)).count
        let largest = StreamMessage.video(.init(header: header, data: Data(repeating: 1, count: StreamFraming.maximumLength - overhead)))
        let data = try StreamFraming.encode(largest)
        XCTAssertEqual(data.count, StreamFraming.maximumLength + 4)
        var decoder = StreamDecoder()
        XCTAssertEqual(try decoder.append(data), [largest])
        XCTAssertThrowsError(try StreamFraming.encode(.video(.init(header: header,
            data: Data(repeating: 1, count: StreamFraming.maximumLength - overhead + 1)))))
        for prefix: Data in [Data([0,128,0,1]), Data([0,0,0,0]), Data([0,0,0,1,3]), Data([0,0,0,5,2,0,0,0,20])] {
            var bad = StreamDecoder(); XCTAssertThrowsError(try bad.append(prefix))
            XCTAssertThrowsError(try bad.append(Data([1])))
        }
        let invalid = StreamVideo(header: .init(agent: "a", pts: 0, keyframe: false, codec: .h264, format: format), data: Data())
        XCTAssertThrowsError(try StreamFraming.encode(.video(invalid)))
    }
    func testDefaultsAndInvalidSubscription() throws {
        let control = try JSONDecoder().decode(StreamControl.self, from: Data(#"{"type":"subscribe","agent":"a"}"#.utf8))
        XCTAssertEqual(control, .subscribe(.init(agent: "a")))
        for fps in [0,31] {
            XCTAssertThrowsError(try JSONDecoder().decode(StreamControl.self, from: Data("{\"type\":\"subscribe\",\"agent\":\"a\",\"max_fps\":\(fps)}".utf8)))
        }
    }
    func testGlobalWindowAndAspectFitCoordinates() {
        let frame = StreamRect(x: -400, y: 50, width: 800, height: 400)
        let window = StreamPoints.windowPoint(global: .init(x: -200, y: 150), frame: frame)
        XCTAssertEqual(window, CGPoint(x: 200, y: 100))
        XCTAssertEqual(StreamPoints.viewPoint(window: window, windowSize: .init(width: 800, height: 400), viewSize: .init(width: 400, height: 400)), CGPoint(x: 100, y: 150))
        XCTAssertEqual(StreamPoints.viewPoint(window: window, windowSize: .init(width: 800, height: 400), viewSize: .init(width: 800, height: 200)), CGPoint(x: 300, y: 50))
        XCTAssertNil(StreamPoints.viewPoint(window: window, windowSize: .zero, viewSize: .init(width: 400, height: 400)))
    }
}
