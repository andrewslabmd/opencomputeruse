import XCTest
@testable import ComputerUseHelper

final class ForegroundGuardTests: XCTestCase {
    final class Fake: ForegroundGuardAccess {
        var front: pid_t? = 100          // the user's app
        var clock = Date(timeIntervalSince1970: 1000)
        var mouseDownAgo: TimeInterval = 999
        var modifierHeld = false
        var restorable = true
        var restores: [pid_t] = []
        func frontmost() -> pid_t? { front }
        func name(_ pid: pid_t) -> String? { "app\(pid)" }
        func secondsSinceMouseDown() -> TimeInterval { mouseDownAgo }
        func switchModifierHeld() -> Bool { modifierHeld }
        func restore(_ pid: pid_t) -> Bool { restores.append(pid); if restorable { front = pid }; return restorable }
        func now() -> Date { clock }
    }
    private func posted(_ fake: Fake, _ guardian: ForegroundGuard, target: pid_t = 200) {
        guardian.arm(target: target); fake.clock += 0.05; guardian.settle()
    }

    func testAppReactingToOCUInputIsRestored() {
        let fake = Fake(); let guardian = ForegroundGuard(access: fake, autoTick: false)
        posted(fake, guardian); fake.front = 200; fake.clock += 0.3; guardian.tick()
        XCTAssertEqual(fake.restores, [100]); XCTAssertEqual(guardian.events(since: 0).map(\.outcome), ["restored"])
    }

    func testUserBringingTheAgentsAppForwardIsNeverFought() {
        // Cmd+Tab to the very app the agent is working in.
        let fake = Fake(); let guardian = ForegroundGuard(access: fake, autoTick: false)
        posted(fake, guardian); fake.modifierHeld = true; guardian.tick(); fake.modifierHeld = false
        fake.front = 200; fake.clock += 0.2; guardian.tick()
        XCTAssertTrue(fake.restores.isEmpty); XCTAssertEqual(guardian.events(since: 0).map(\.outcome), ["user_switch"])
        // A click on the agent's window, including one just before OCU's input.
        let fake2 = Fake(); let guardian2 = ForegroundGuard(access: fake2, autoTick: false)
        fake2.mouseDownAgo = 0.4; posted(fake2, guardian2); fake2.front = 200; fake2.clock += 0.1; guardian2.tick()
        XCTAssertTrue(fake2.restores.isEmpty)
    }

    func testAtMostOneCorrectionThenTheUserIsLeftAlone() {
        let fake = Fake(); let guardian = ForegroundGuard(access: fake, autoTick: false)
        posted(fake, guardian); fake.front = 200; fake.clock += 0.2; guardian.tick()
        fake.front = 200; fake.clock += 0.1; guardian.tick()   // switched again, no new OCU input
        XCTAssertEqual(fake.restores, [100])
    }

    func testNothingIsWatchedWithoutOCUInputOrAfterTheWindow() {
        let fake = Fake(); let guardian = ForegroundGuard(access: fake, autoTick: false)
        fake.front = 200; guardian.tick()
        XCTAssertTrue(fake.restores.isEmpty)
        posted(fake, guardian); fake.clock += ForegroundGuard.settleWindow + 0.1; guardian.tick()
        fake.front = 300; guardian.tick()
        XCTAssertTrue(fake.restores.isEmpty)
    }

    func testWorkingInTheFrontAppNeverTriggers() {
        let fake = Fake(); let guardian = ForegroundGuard(access: fake, autoTick: false)
        posted(fake, guardian, target: 100); fake.clock += 0.2; guardian.tick()
        XCTAssertTrue(fake.restores.isEmpty); XCTAssertTrue(guardian.events(since: 0).isEmpty)
    }

    func testFailedRestoreIsReportedOnce() {
        let fake = Fake(); fake.restorable = false; let guardian = ForegroundGuard(access: fake, autoTick: false)
        posted(fake, guardian); fake.front = 200; fake.clock += 0.2; guardian.tick(); guardian.tick()
        XCTAssertEqual(fake.restores, [100]); XCTAssertEqual(guardian.events(since: 0).map(\.outcome), ["restore_failed"])
    }
}
