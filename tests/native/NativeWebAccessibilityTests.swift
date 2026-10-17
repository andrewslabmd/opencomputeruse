import XCTest
@testable import ComputerUseHelper

final class NativeWebAccessibilityTests: XCTestCase {
    final class FakeAccess: WebAccessibilityAccess {
        var settable = true, settableError: Error?, requested: [pid_t] = []
        func switchSettable(_ pid: pid_t) throws -> Bool { if let settableError { throw settableError }; return settable }
        func requestComplete(_ pid: pid_t) throws { requested.append(pid) }
    }
    let first = NativeProcessIdentity(pid: 42, uid: 501, startSeconds: 10, startMicroseconds: 1)

    func testRequestsOncePerProcessAndWaitsOnlyForTheRemainingDebounce() throws {
        let access = FakeAccess(); var clock = Date(timeIntervalSince1970: 1000)
        let mode = WebAccessibilityMode(access: access, now: { clock })
        XCTAssertEqual(try mode.prepare(first), WebAccessibilityMode.readiness)
        clock += 1
        XCTAssertEqual(try XCTUnwrap(mode.prepare(first)), WebAccessibilityMode.readiness - 1, accuracy: 0.0001)
        clock += 5
        XCTAssertEqual(try mode.prepare(first), 0)
        XCTAssertEqual(access.requested, [42])
    }

    func testReplacedProcessWithSamePIDGetsItsOwnRequest() throws {
        let access = FakeAccess(); let mode = WebAccessibilityMode(access: access, now: { Date(timeIntervalSince1970: 0) })
        _ = try mode.prepare(first)
        let replacement = NativeProcessIdentity(pid: 42, uid: 501, startSeconds: 20, startMicroseconds: 0)
        XCTAssertEqual(try mode.prepare(replacement), WebAccessibilityMode.readiness)
        XCTAssertEqual(access.requested, [42, 42])
    }

    func testTargetsWithoutTheSwitchAreUnchangedAndUnwaited() throws {
        let access = FakeAccess(); access.settable = false
        let mode = WebAccessibilityMode(access: access)
        XCTAssertNil(try mode.prepare(first))
        XCTAssertNil(try mode.prepare(first))
        XCTAssertTrue(access.requested.isEmpty)
    }

    func testProviderFailureIsAnErrorNotASilentSkip() {
        let access = FakeAccess(); access.settableError = WebAccessibilityFailure(message: "AXError -25204")
        XCTAssertThrowsError(try WebAccessibilityMode(access: access).prepare(first))
        XCTAssertTrue(access.requested.isEmpty)
    }

}
