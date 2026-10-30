import XCTest
@testable import ComputerUseHelper

final class LiveTestActivityTests: XCTestCase {
    func testRequiresUnlockedBackgroundAndFiveMinutes() {
        var guardState = LiveTestActivity(helperPID: 42)
        guardState.sample(unlocked:false,idle:900,background:true)
        XCTAssertFalse(guardState.qualified)
        guardState.sample(unlocked:true,idle:900,background:false)
        XCTAssertFalse(guardState.qualified)
        guardState.sample(unlocked:true,idle:299,background:true)
        XCTAssertFalse(guardState.qualified)
        guardState.sample(unlocked:true,idle:300,background:true)
        XCTAssertTrue(guardState.qualified)
        guardState.event(sourcePID:42,privateSource:true,tag:1)
        guardState.sample(unlocked:true,idle:0,background:true)
        XCTAssertFalse(guardState.stopped) // Own HID idle reset does not end qualification.
        guardState.event(sourcePID:0,privateSource:false,tag:0)
        XCTAssertTrue(guardState.stopped) // Even immediately beside our own input.
        guardState.sample(unlocked:true,idle:999,background:true)
        XCTAssertTrue(guardState.stopped) // No automatic restart.
    }
    func testUnknownInputLockFocusChangeOrLostMonitorStops() {
        for event in [(Int64(43),true,Int64(1)),(Int64(42),false,Int64(1)),(Int64(42),true,Int64(0))] {
            var state=LiveTestActivity(helperPID:42)
            state.sample(unlocked:true,idle:300,background:true)
            state.event(sourcePID:event.0,privateSource:event.1,tag:event.2)
            XCTAssertTrue(state.stopped)
        }
        for (unlocked, background) in [(false,true),(true,false)] {
            var state=LiveTestActivity(helperPID:42)
            state.sample(unlocked:true,idle:300,background:true)
            state.sample(unlocked:unlocked,idle:301,background:background)
            XCTAssertTrue(state.stopped)
        }
        var state=LiveTestActivity(helperPID:42); state.monitorLost()
        state.sample(unlocked:true,idle:999,background:true)
        XCTAssertTrue(state.stopped)
    }
}
