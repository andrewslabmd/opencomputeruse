import XCTest
import CoreGraphics
@testable import ComputerUseHelper

final class NativeAppListTests: XCTestCase {
    private func app(_ pid: pid_t, _ name: String, regular: Bool = true, hidden: Bool = false, executable: String? = nil) -> NativeAppListApplication {
        .init(candidate: .init(pid: pid, bundleIdentifier: "com.example.\(name.lowercased())", localizedName: name,
            bundleURL: nil, executableURL: executable.map { URL(fileURLWithPath: $0) }), regular: regular, hidden: hidden)
    }
    private func window(_ id: Int, owner: pid_t, title: String? = nil, onScreen: Bool = true, layer: Int = 0) -> [String: Any] {
        var info: [String: Any] = [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: owner),
            kCGWindowLayer as String: NSNumber(value: layer), kCGWindowIsOnscreen as String: NSNumber(value: onScreen)]
        if let title { info[kCGWindowName as String] = title }
        return info
    }

    func testListsRegularAppsAndVisibleAccessoryAppsWithTheirNormalWindows() {
        let entries = NativeAppList.entries(
            [app(20, "Notes", hidden: true), app(10, "Safari"), app(30, "Agent", regular: false), app(40, "Panel", regular: false)],
            windows: [window(1, owner: 10, title: "Start Page"), window(2, owner: 10, title: "Downloads", onScreen: false),
                      window(3, owner: 10), window(4, owner: 10, onScreen: false), window(5, owner: 10, title: "Menu", layer: 25),
                      window(6, owner: 40, title: "Inspector")],
            frontmost: 20, livePIDs: { _ in [] })
        XCTAssertEqual(entries.map(\.name), ["Notes", "Panel", "Safari"])
        XCTAssertEqual(entries[0].frontmost, true); XCTAssertEqual(entries[0].hidden, true); XCTAssertEqual(entries[0].windows, [])
        XCTAssertNil(entries[2].frontmost); XCTAssertNil(entries[2].hidden)
        // Untitled offscreen buffers and non-normal layers are internal.
        XCTAssertEqual(entries[2].windows, [.init(window_id: 1, title: "Start Page", on_screen: true),
            .init(window_id: 2, title: "Downloads", on_screen: false), .init(window_id: 3, title: nil, on_screen: true)])
    }

    func testLaunchServicesEntriesWithoutAPidAreRecoveredOrLeftOut() {
        let entries = NativeAppList.entries(
            [app(-1, "Device Hub", executable: "/Apps/DeviceHub"), app(-1, "Gone", executable: "/Apps/Gone"), app(50, "Device Hub Copy")],
            windows: [], frontmost: nil, livePIDs: { $0 == "/Apps/DeviceHub" ? [77] : [] })
        XCTAssertEqual(entries.map(\.pid), [77, 50]); XCTAssertEqual(entries.map(\.name), ["Device Hub", "Device Hub Copy"])
    }
}
