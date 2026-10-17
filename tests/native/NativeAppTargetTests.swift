import XCTest
@testable import ComputerUseHelper

final class NativeAppTargetTests: XCTestCase {
    // Xcode's embedded Device Hub as LaunchServices reports it: listed, pid -1.
    private let deviceHub = NativeAppCandidate(pid: -1, bundleIdentifier: "com.apple.dt.Devices",
        localizedName: "Device Hub",
        bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"),
        executableURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub"))
    private let finder = NativeAppCandidate(pid: 500, bundleIdentifier: "com.apple.finder", localizedName: "Finder",
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), executableURL: nil)

    private func resolve(_ target: String, live: [String: [pid_t]] = [:]) -> pid_t? {
        NativeAppTarget.resolve(target, candidates: [finder, deviceHub]) { live[$0] ?? [] }
    }

    func testListedAppWithoutPIDResolvesToItsRunningExecutable() {
        let live: [String: [pid_t]] = [deviceHub.executableURL!.path: [58046]]
        for target in ["Device Hub", "device hub", "com.apple.dt.Devices", "DeviceHub", "DeviceHub.app"] {
            XCTAssertEqual(resolve(target, live: live), 58046, target)
        }
    }

    func testListedAppWithoutLiveProcessNeverResolvesToInvalidPID() {
        XCTAssertNil(resolve("Device Hub"))
        XCTAssertNil(resolve("com.apple.dt.Devices", live: [deviceHub.executableURL!.path: [-1, 0]]))
    }

    func testExplicitAndListedTargetsKeepTheirMeaning() {
        XCTAssertEqual(resolve("pid:42"), 42)
        XCTAssertEqual(resolve("42"), 42)
        XCTAssertNil(resolve("pid:0")); XCTAssertNil(resolve("-1")); XCTAssertNil(resolve("  "))
        XCTAssertEqual(resolve("Finder"), 500)
        XCTAssertEqual(resolve("com.apple.finder"), 500)
        XCTAssertNil(resolve("com.apple.Finder"))   // bundle IDs match exactly
        XCTAssertNil(resolve("Missing"))
    }

    // Pointer/keyboard input watches the frontmost app; Device Hub in front is listed as pid -1.
    func testFrontmostAppWithoutPIDIsWatchedByItsRunningProcessOrUnknown() {
        let live: [String: [pid_t]] = [deviceHub.executableURL!.path: [58046]]
        XCTAssertEqual(NativeAppTarget.livePID(deviceHub) { live[$0] ?? [] }, 58046)
        XCTAssertNil(NativeAppTarget.livePID(deviceHub) { _ in [] })
        XCTAssertEqual(NativeAppTarget.livePID(finder) { _ in [] }, 500)
        if let front = NativeAppTarget.frontmostPID() { XCTAssertGreaterThan(front, 0) }
    }

    func testLivePIDsFindsThisUsersProcessByExecutablePath() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertTrue(NativeAppTarget.livePIDs(executablePath: "/bin/sleep").contains(process.processIdentifier))
        XCTAssertTrue(NativeAppTarget.livePIDs(executablePath: "/nonexistent/ocu-test").isEmpty)
    }
}
