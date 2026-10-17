import XCTest
@testable import ComputerUseHelper

private final class FocusAccess: BackgroundAppFocusAccess {
    var app = NativeProcessIdentity(pid: 42, uid: 503, startSeconds: 1, startMicroseconds: 1)
    var foreground: pid_t? = 7
    var active: Bool? = false
    var notifications: [Bool] = []
    var failActivation = false
    var failRestoration = false
    var failIdentity = false
    var onNotification: ((Bool) -> Void)?
    var onForegroundRead: (() -> Void)?
    func identity(_ pid: pid_t) throws -> NativeProcessIdentity? {
        if failIdentity { throw NativeProcessIdentityFailure(message: "identity unavailable") }
        return pid == app.pid ? app : nil
    }
    func foregroundPID() -> pid_t? { onForegroundRead?(); return foreground }
    func logicalActive(_ pid: pid_t) throws -> Bool? { active }
    func notify(_ pid: pid_t, active: Bool) throws {
        notifications.append(active); self.active = active; onNotification?(active)
        if active && failActivation { throw BackgroundAppFocusFailure(message: "uncertain activation") }
    }
    func waitForState(_ pid: pid_t, active: Bool, cancelled: () -> Bool) throws {
        if cancelled() { return }
        if !active && failRestoration { throw BackgroundAppFocusFailure(message: "unconfirmed restoration") }
        XCTAssertEqual(self.active, active)
    }
}

final class BackgroundAppFocusTests: XCTestCase {
    func testOverflowItemStillRequiresRetainedNativeAncestry() throws {
        let item = NativeInteractionNode(id: "item", role: "AXMenuItem", subrole: nil, frame: CGRect(x: 20,y: 5,width: 100,height: 20),children: [])
        let menu = NativeInteractionNode(id: "menu", role: "AXMenu", subrole: nil, frame: CGRect(x: 20,y: 0,width: 100,height: 60),children: [item])
        let root = NativeInteractionNode(id: "window", role: "AXWindow", subrole: nil, frame: CGRect(x: 0,y: 50,width: 200,height: 150),children: [menu])
        XCTAssertEqual(try NativePointResolver.chain(root: root,nativeHitIDs: ["item","menu","window"],point: CGPoint(x: 30,y: 10)).map(\.id),["item","menu"])
        XCTAssertThrowsError(try NativePointResolver.chain(root: root,nativeHitIDs: ["item","foreign"],point: CGPoint(x: 30,y: 10)))
    }
    private func begin(_ manager: BackgroundAppFocus) throws -> BackgroundAppFocusResult {
        try manager.begin(pid: 42, owner: 123, watchOwner: false, guardEvents: false)
    }
    func testActionActivatesAndRestoresOnlyOwnedState() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access)
        let lease = try begin(manager)
        XCTAssertEqual(lease.mode, "synthetic"); XCTAssertEqual(access.active, true)
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "restored")
        XCTAssertEqual(access.notifications, [true, false]); XCTAssertEqual(access.foreground, 7)
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "already_released")
    }
    func testWorkflowReusesActivationForFollowingMenuAction() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access)
        let first = try begin(manager); let second = try begin(manager)
        XCTAssertEqual(first.token, second.token); XCTAssertEqual(access.notifications, [true])
        _ = try manager.release(owner: 123); XCTAssertEqual(access.notifications, [true, false])
    }
    func testObservingAnotherTargetRestoresPreviousApp() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access)
        _ = try begin(manager); try manager.releaseIfTargetChanged(identity: NativeProcessIdentity(pid: 99, uid: 503, startSeconds: 1, startMicroseconds: 1), owner: 123)
        XCTAssertEqual(access.notifications, [true, false])
    }
    func testOtherOwnerCannotReleaseWorkflow() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        XCTAssertThrowsError(try manager.end(token: lease.token, owner: 888)); XCTAssertEqual(access.notifications, [true])
        _ = try manager.end(token: lease.token, owner: 123)
    }
    func testExistingLogicalActivationIsPreserved() throws {
        let access = FocusAccess(); access.active = true
        let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        XCTAssertEqual(lease.mode, "already_active")
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "preserved")
        XCTAssertTrue(access.notifications.isEmpty)
    }
    func testRealForegroundAppIsNotSyntheticallyChanged() throws {
        let access = FocusAccess(); access.foreground = 42
        let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        XCTAssertEqual(lease.mode, "user_active")
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "user_active")
        XCTAssertTrue(access.notifications.isEmpty)
    }
    func testUserActivationDuringActionBelongsToUserEvenAfterSwitchingAway() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        manager.userActivated(42); access.foreground = 9
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "user_active")
        XCTAssertEqual(access.notifications, [true])
    }
    func testReusedTargetPIDIsNotDeactivated() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        access.app = NativeProcessIdentity(pid: 42, uid: 503, startSeconds: 1, startMicroseconds: 2)
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "process_exited")
        XCTAssertEqual(access.notifications, [true])
    }
    func testPIDReuseBetweenCleanupCheckAndEventDeliveryIsPreserved() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        access.onForegroundRead = {
            access.onForegroundRead = nil
            access.app = NativeProcessIdentity(pid: 42, uid: 503, startSeconds: 1, startMicroseconds: 2)
        }
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "process_exited")
        XCTAssertEqual(access.notifications, [true])
    }
    func testUncertainActivationStillRestores() {
        let access = FocusAccess(); access.failActivation = true
        let manager = BackgroundAppFocus(access: access)
        XCTAssertThrowsError(try begin(manager)); XCTAssertEqual(access.notifications, [true, false])
    }
    func testUnavailableIdentityDoesNotMeanExitedOrSendEvents() throws {
        let access = FocusAccess(); access.failIdentity = true
        let manager = BackgroundAppFocus(access: access)
        XCTAssertThrowsError(try begin(manager)) { XCTAssertEqual($0.localizedDescription, "identity unavailable") }
        XCTAssertTrue(access.notifications.isEmpty)
    }
    func testUnavailableCleanupIdentityRetainsOwnershipUntilConfirmed() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        access.failIdentity = true
        XCTAssertThrowsError(try manager.end(token: lease.token))
        XCTAssertEqual(access.notifications, [true])
        access.failIdentity = false
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "restored")
        XCTAssertEqual(access.notifications, [true, false])
    }
    func testLookupFailureBeforeRestorationDispatchCanRecoverWithoutLostCleanup() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        access.onForegroundRead = { access.onForegroundRead = nil; access.failIdentity = true }
        XCTAssertThrowsError(try manager.end(token: lease.token))
        XCTAssertEqual(access.notifications, [true])
        access.failIdentity = false
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "restored")
        XCTAssertEqual(access.notifications, [true, false])
    }
    func testHandoffToReusedPIDDoesNotKeepOldLease() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access)
        _ = try begin(manager)
        access.app = NativeProcessIdentity(pid: 42, uid: 503, startSeconds: 1, startMicroseconds: 2)
        try manager.releaseIfTargetChanged(identity: access.app, owner: 123)
        let replacement = try begin(manager)
        XCTAssertEqual(access.notifications, [true]) // existing logical state is preserved
        XCTAssertEqual(replacement.mode, "already_active")
        _ = try manager.release(owner: 123)
    }
    func testUnconfirmedCleanupStopsNewActionsAndDoesNotRepeatNotification() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        access.failRestoration = true
        XCTAssertThrowsError(try manager.end(token: lease.token)); XCTAssertThrowsError(try begin(manager))
        access.failRestoration = false
        XCTAssertEqual(try manager.end(token: lease.token).cleanup, "restored")
        XCTAssertEqual(access.notifications, [true, false])
    }
    func testUnknownProviderDoesNotGetInventedActivation() throws {
        let access = FocusAccess(); access.active = nil
        let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        XCTAssertEqual(lease.mode, "state_unavailable"); _ = try manager.end(token: lease.token)
        XCTAssertTrue(access.notifications.isEmpty)
    }
    func testEventGuardOnlySuppressesOwnedBackgroundDeactivation() throws {
        let access = FocusAccess(); let manager = BackgroundAppFocus(access: access); let lease = try begin(manager)
        XCTAssertTrue(manager.suppressDeactivation(pid: 42, sourcePID: 0))
        XCTAssertFalse(manager.suppressDeactivation(pid: 42, sourcePID: getpid()))
        XCTAssertFalse(manager.suppressDeactivation(pid: 42, sourcePID: 888))
        access.foreground = 42
        XCTAssertTrue(manager.suppressDeactivation(pid: 42, sourcePID: getpid()))
        XCTAssertFalse(manager.suppressDeactivation(pid: 42, sourcePID: 0))
        _ = try manager.end(token: lease.token)
    }
    func testOwnerExitCleansUpWithoutHelperMainThreadRequest() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let access = FocusAccess(); let restored = expectation(description: "owner exit restored focus")
        access.onNotification = { if !$0 { restored.fulfill() } }
        let manager = BackgroundAppFocus(access: access)
        _ = try manager.begin(pid: 42, owner: process.processIdentifier, guardEvents: false)
        process.terminate(); wait(for: [restored], timeout: 3)
        XCTAssertEqual(access.active, false)
        withExtendedLifetime(manager) {}
    }

    func testTwoAgentsKeepSeparateLeasesAndNeverShareAnApp() throws {
        final class TwoApps: BackgroundAppFocusAccess {
            var apps: [pid_t: NativeProcessIdentity] = [42: .init(pid: 42, uid: 503, startSeconds: 1, startMicroseconds: 1),
                                                       43: .init(pid: 43, uid: 503, startSeconds: 1, startMicroseconds: 1)]
            var active: [pid_t: Bool] = [42: false, 43: false]
            var notifications: [String] = []
            func identity(_ pid: pid_t) throws -> NativeProcessIdentity? { apps[pid] }
            func foregroundPID() -> pid_t? { 7 }
            func logicalActive(_ pid: pid_t) throws -> Bool? { active[pid] }
            func notify(_ pid: pid_t, active: Bool) throws { notifications.append("\(pid):\(active)"); self.active[pid] = active }
            func waitForState(_ pid: pid_t, active: Bool, cancelled: () -> Bool) throws {}
        }
        let access = TwoApps(); let manager = BackgroundAppFocus(access: access)
        let first = try manager.begin(pid: 42, owner: 123, watchOwner: false, guardEvents: false)
        let second = try manager.begin(pid: 43, owner: 456, watchOwner: false, guardEvents: false)
        XCTAssertNotEqual(first.token, second.token); XCTAssertEqual(access.active, [42: true, 43: true])
        XCTAssertThrowsError(try manager.begin(pid: 42, owner: 456, watchOwner: false, guardEvents: false)) {
            XCTAssertEqual($0.localizedDescription, "Another agent holds this app's background focus.")
        }
        XCTAssertThrowsError(try manager.end(token: first.token, owner: 456))
        XCTAssertTrue(manager.suppressDeactivation(pid: 43, sourcePID: 0))
        _ = try manager.release(owner: 123)
        XCTAssertEqual(access.active, [42: false, 43: true]); XCTAssertTrue(manager.hasLeases)
        XCTAssertEqual(try manager.begin(pid: 43, owner: 456, watchOwner: false, guardEvents: false).token, second.token)
        _ = try manager.release()
        XCTAssertEqual(access.notifications, ["42:true", "43:true", "42:false", "43:false"]); XCTAssertFalse(manager.hasLeases)
    }
}
