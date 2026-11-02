import XCTest
import OCUStream

final class PiPStateTests: XCTestCase {
    func testEveryTargetStateAndExactText() {
        let cases: [(StreamTargetState?, PiPState, String?)] = [
            (.live, .live, nil), (.minimized, .minimized, "Minimized"), (.hidden, .hidden, "Hidden"),
            (.closed, .closed, "Window closed"), (.idle, .noTarget, "Not working in an app"),
            (nil, .noTarget, "Not working in an app"), (.stopped, .stopped, "Stopped"),
            (.hidden_from_capture, .unavailable, "This window can't be shown."),
            (.no_permission, .noPermission, "Screen Recording is off")]
        for (input, expected, text) in cases {
            let state = PiPState(target: input)
            XCTAssertEqual(state, expected); XCTAssertEqual(state.text, text)
            XCTAssertEqual(state.keepsLastFrame, [.live, .minimized, .hidden].contains(state))
            XCTAssertEqual(state.dimsLastFrame, [.minimized, .hidden].contains(state))
        }
    }
    func testEveryEndReasonAndPrecedence() {
        let cases: [(StreamEndReason, PiPState)] = [
            (.released, .noTarget), (.disconnected, .disconnected), (.stopped, .stopped),
            (.paused, .stopped), (.unsubscribed, .noTarget), (.capture_stopped_by_user, .stopped), (.error, .unavailable)]
        for (reason, expected) in cases { XCTAssertEqual(PiPState(target: .live, end: reason), expected) }
        XCTAssertEqual(PiPState(target: .live, stopped: true), .stopped)
        XCTAssertEqual(PiPState(target: .minimized, noPermission: true), .noPermission)
        XCTAssertEqual(PiPState(target: .live, stopped: true, noPermission: true), .stopped)
        XCTAssertEqual(PiPState(target: .live, end: .disconnected, stopped: true), .disconnected)
        XCTAssertNil(PiPState.disconnected.text)
    }
    func testResizeRangeHeightCapAndAspectFit() {
        let size = CGSize(width: 1440, height: 900)
        XCTAssertEqual(PiPGeometry.size(windowSize: size), CGSize(width: 360, height: 225))
        XCTAssertEqual(PiPGeometry.size(width: 100, windowSize: size), CGSize(width: 240, height: 150))
        XCTAssertEqual(PiPGeometry.size(width: 900, windowSize: size), CGSize(width: 720, height: 300))
        XCTAssertEqual(PiPGeometry.size(windowSize: CGSize(width: 300, height: 900)), CGSize(width: 360, height: 300))
        XCTAssertEqual(PiPGeometry.size(windowSize: .zero), CGSize(width: 360, height: 300))
        for width: CGFloat in [240, 360, 480, 720] {
            let view = PiPGeometry.size(width: width, windowSize: size)
            let center = PiPGeometry.viewPoint(window: CGPoint(x: 720, y: 450), windowSize: size, viewSize: view)
            XCTAssertEqual(center, CGPoint(x: view.width / 2, y: view.height / 2))
        }
        // Horizontal bars, vertical bars, and no backing-pixel multiplication.
        XCTAssertEqual(PiPGeometry.viewPoint(window: .zero, windowSize: CGSize(width: 800, height: 400),
                                            viewSize: CGSize(width: 400, height: 400)), CGPoint(x: 0, y: 100))
        XCTAssertEqual(PiPGeometry.viewPoint(window: CGPoint(x: 200, y: 100), windowSize: CGSize(width: 800, height: 400),
                                            viewSize: CGSize(width: 800, height: 200)), CGPoint(x: 300, y: 50))
        XCTAssertNil(PiPGeometry.viewPoint(window: .zero, windowSize: .zero, viewSize: size))
        XCTAssertNil(PiPGeometry.viewPoint(window: .zero, windowSize: size, viewSize: .zero))
    }
}
