import AppKit
import XCTest
@testable import ComputerUseHelper

final class NativeProcessIdentityTests: XCTestCase {
    func testRunningCommandLineProcessHasIdentityWithoutLaunchServicesMetadata() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertNil(NSRunningApplication(processIdentifier: process.processIdentifier)?.launchDate)
        let identity = try XCTUnwrap(NativeProcessIdentity.read(process.processIdentifier))
        XCTAssertEqual(identity.pid, process.processIdentifier)
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertEqual(try NativeProcessIdentity.read(process.processIdentifier), identity)
        XCTAssertEqual(try AXBackgroundAppFocusAccess().identity(process.processIdentifier), identity)
        process.terminate(); process.waitUntilExit()
        XCTAssertNil(try NativeProcessIdentity.read(process.processIdentifier))
    }
    func testInvalidPIDDoesNotResolveCallingProcessOrBecomeAbsentMetadata() {
        for pid: pid_t in [0, -1] {
            XCTAssertThrowsError(try NativeProcessIdentity.read(pid))
        }
    }
}
