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
    func testInlineHeightCapAndAspectFitCursorAtSixtyPercent() {
        let window = CGSize(width: 1440, height: 900)
        XCTAssertEqual(InlinePreviewGeometry.size(width: 274, windowSize: window), CGSize(width: 274, height: 171.25))
        XCTAssertEqual(InlinePreviewGeometry.size(width: 400, windowSize: window), CGSize(width: 400, height: 220))
        XCTAssertEqual(InlinePreviewGeometry.size(width: 274, windowSize: CGSize(width: 300, height: 900)), CGSize(width: 274, height: 220))
        XCTAssertEqual(InlinePreviewGeometry.size(width: 274, windowSize: .zero), CGSize(width: 274, height: 220))
        XCTAssertEqual(InlinePreviewGeometry.size(width: 0, windowSize: window), .zero)
        XCTAssertEqual(InlinePreviewGeometry.cursorScale, 0.6)
        for size in [CGSize(width: 274, height: 171.25), CGSize(width: 400, height: 220)] {
            let point = InlinePreviewGeometry.cursorPoint(window: CGPoint(x: 720, y: 450), windowSize: window, viewSize: size)!
            XCTAssertEqual(point.x * 0.6, size.width / 2, accuracy: 0.001)
            XCTAssertEqual(point.y * 0.6, size.height / 2, accuracy: 0.001)
            let canvas = InlinePreviewGeometry.cursorCanvas(viewSize: size)
            XCTAssertEqual(canvas.width * 0.6, size.width, accuracy: 0.001)
            XCTAssertEqual(canvas.height * 0.6, size.height, accuracy: 0.001)
        }
        // A tall target is centered horizontally; the same transform applies
        // to the drag's endpoint and to a typing cursor. Retina is not multiplied.
        let tall = CGSize(width: 300, height: 900), view = CGSize(width: 274, height: 220)
        let origin = InlinePreviewGeometry.cursorPoint(window: .zero, windowSize: tall, viewSize: view)!
        XCTAssertEqual(origin.x * 0.6, (274 - 300 * 220.0 / 900) / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, 0)
        let end = InlinePreviewGeometry.cursorPoint(window: CGPoint(x: 300, y: 900), windowSize: tall, viewSize: view)!
        XCTAssertEqual(end.x * 0.6, 274 - origin.x * 0.6, accuracy: 0.001)
        XCTAssertEqual(end.y * 0.6, 220, accuracy: 0.001)
        XCTAssertNil(InlinePreviewGeometry.cursorPoint(window: .zero, windowSize: .zero, viewSize: view))
        XCTAssertNil(InlinePreviewGeometry.cursorPoint(window: .zero, windowSize: tall, viewSize: .zero))
    }
}
