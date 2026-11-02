import Foundation
import OCUStream
import XCTest
@testable import ComputerUseHelper

final class StreamServerAgentsTests: XCTestCase {
    private final class Windows: StreamWindowProvider {
        var info: StreamWindowInfo? = .init(frame: .init(x: 100, y: 200, width: 800, height: 400))
        var calls: [(UInt32, Int32)] = []
        func window(id: UInt32, pid: Int32) -> StreamWindowInfo? { calls.append((id,pid)); return info }
    }
    func testMissingOrDamagedFilesWithdrawStateAndNeverReuseCursorForAnotherWindow() throws {
        let fixture = try StreamTestFixture(), windows = Windows()
        let agents = StreamAgents(commandDirectory: fixture.commands, windows: windows)
        let initial = agents.read()
        XCTAssertEqual(initial.agents.count, 1); XCTAssertEqual(initial.cursors["a"]?.x, 25)
        XCTAssertEqual(windows.calls.first?.0, 42); XCTAssertEqual(windows.calls.first?.1, 123)
        // Window geometry is refreshed even when no JSON file changes.
        windows.info?.frame.x = 110
        XCTAssertEqual(agents.read().cursors["a"]?.x, 15)
        try fixture.cursors(window: 99)
        XCTAssertTrue(agents.read().cursors.isEmpty)
        try fixture.write("cursors.json", "malformed")
        XCTAssertTrue(agents.read().cursors.isEmpty)
        XCTAssertEqual(agents.read().agents.count, 1) // a target need not yet have a cursor
        try fixture.write("targets.json", "malformed")
        XCTAssertTrue(agents.read().agents.isEmpty)
        try fixture.targets()
        XCTAssertEqual(agents.read().agents.count, 1)
        try FileManager.default.removeItem(at: fixture.runtime.appendingPathComponent("targets.json"))
        XCTAssertTrue(agents.read().agents.isEmpty)
        try fixture.targets()
        try FileManager.default.removeItem(at: fixture.runtime.appendingPathComponent("status.json"))
        XCTAssertTrue(agents.read().paused); XCTAssertTrue(agents.read().agents.isEmpty)
    }
    func testWindowMustBelongToProvenSetAndMissingWindowReportsClosed() throws {
        let fixture = try StreamTestFixture(), windows = Windows()
        let agents = StreamAgents(commandDirectory: fixture.commands, windows: windows)
        windows.info = nil
        XCTAssertEqual(agents.read().targets["a"]?.state, .closed)
        try fixture.write("targets.json", """
        [{"client":"a","name":"Agent","slot":0,"busy":false,"pid":123,"app_name":"Fixture","bundle_id":"test","window_ids":[41],"main_window_id":42,"at":0}]
        """)
        XCTAssertTrue(agents.read().targets.isEmpty)
    }
    func testNullAppMetadataKeepsTheAgent() throws {
        let fixture = try StreamTestFixture(), windows = Windows()
        let agents = StreamAgents(commandDirectory: fixture.commands, windows: windows)
        try fixture.write("targets.json", """
        [{"client":"a","name":"Agent","slot":0,"busy":false,"pid":123,"app_name":null,"bundle_id":null,"window_ids":[42],"main_window_id":42,"at":0}]
        """)
        let snapshot = agents.read()
        XCTAssertEqual(snapshot.agents.count, 1); XCTAssertNil(snapshot.agents.first?.app_name)
    }
    func testControlBooleanDoesNotAcceptNumberAndSymlinkIsNotRead() throws {
        let fixture = try StreamTestFixture(), windows = Windows()
        let agents = StreamAgents(commandDirectory: fixture.commands, windows: windows)
        for state in [#"{"paused":0}"#, #"{"paused":null}"#, "[]", "{}"] {
            try fixture.write("status.json", state)
            XCTAssertTrue(agents.read().paused)
        }
        try fixture.write("status.json", #"{"paused":false}"#)
        let path = fixture.runtime.appendingPathComponent("targets.json")
        let moved = fixture.runtime.appendingPathComponent("saved-targets.json")
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        XCTAssertTrue(agents.read().agents.isEmpty)
    }
}
