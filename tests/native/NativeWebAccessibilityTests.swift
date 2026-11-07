import XCTest
@testable import ComputerUseHelper

final class NativeWebAccessibilityTests: XCTestCase {
    final class FakeAccess: WebAccessibilityAccess {
        var settable = true, settableError: Error?, requestError: Error?, requested: [pid_t] = []
        func switchSettable(_ pid: pid_t) throws -> Bool { if let settableError { throw settableError }; return settable }
        func requestComplete(_ pid: pid_t) throws { if let requestError { throw requestError }; requested.append(pid) }
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

    func testSnapshotPreparationRecoversAXFailureOnlyAfterDefiniteKernelExit() throws {
        for duringRequest in [false, true] {
            let access = FakeAccess()
            let failure = WebAccessibilityFailure(message: "AXError -25204")
            if duringRequest { access.requestError = failure } else { access.settableError = failure }
            let mode = WebAccessibilityMode(access: access)
            var checkedCancellation = false
            let result = try mode.prepareSnapshot(first, checkCancellation: { checkedCancellation = true },
                readIdentity: { pid in
                    XCTAssertTrue(checkedCancellation)
                    XCTAssertEqual(pid, self.first.pid)
                    return nil // Process disappeared after the initial identity read.
                })
            guard case .exited = result else { return XCTFail("Must publish terminal exit after AX disconnect") }
        }
    }

    func testSnapshotPreparationPreservesAXFailureForLiveReplacedOrUnreadableProcess() {
        let access = FakeAccess(); access.settableError = WebAccessibilityFailure(message: "AXError -25204")
        let mode = WebAccessibilityMode(access: access)
        let replacement = NativeProcessIdentity(pid: first.pid, uid: first.uid, startSeconds: 20, startMicroseconds: 0)
        let readers: [(pid_t) throws -> NativeProcessIdentity?] = [
            { _ in self.first }, { _ in replacement },
            { _ in throw NativeProcessIdentityFailure(message: "kernel lookup failed") }
        ]
        for reader in readers {
            XCTAssertThrowsError(try mode.prepareSnapshot(first, checkCancellation: {}, readIdentity: reader)) {
                XCTAssertEqual(($0 as? WebAccessibilityFailure)?.message, "AXError -25204")
            }
        }
        XCTAssertThrowsError(try mode.prepareSnapshot(first, checkCancellation: {
            throw NativeProcessIdentityFailure(message: "cancelled")
        }, readIdentity: { _ in XCTFail("Cancelled request must not infer exit"); return nil }))
    }

    func testSuccessfulSnapshotPreparationDoesNotCheckForExit() throws {
        let access = FakeAccess(); access.settable = false
        let result = try WebAccessibilityMode(access: access).prepareSnapshot(first,
            checkCancellation: { XCTFail("No failure to recover") },
            readIdentity: { _ in XCTFail("No extra kernel lookup on success"); return nil })
        guard case .ready(nil) = result else { return XCTFail("Native target needs no debounce") }
    }

}
