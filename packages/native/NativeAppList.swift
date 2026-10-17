import AppKit
import CoreGraphics

// Read-only inventory of running applications with a user interface, for an
// agent choosing an observe target. Nothing is activated or observed: names
// and window titles come from NSWorkspace and the Window Server's window list
// (titles need Screen Recording, which observation already requires).
struct NativeAppListWindow: Encodable, Equatable {
    let window_id: CGWindowID
    let title: String?
    let on_screen: Bool
}

struct NativeAppListEntry: Encodable, Equatable {
    let name: String
    let bundle_id: String?
    let pid: pid_t
    var frontmost: Bool? = nil
    var hidden: Bool? = nil
    var windows: [NativeAppListWindow]
}

struct NativeAppListApplication {
    let candidate: NativeAppCandidate
    let regular: Bool
    let hidden: Bool
}

enum NativeAppList {
    static func current() -> [NativeAppListEntry] {
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            NativeAppListApplication(candidate: NativeAppCandidate($0), regular: $0.activationPolicy == .regular, hidden: $0.isHidden)
        }
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries(applications, windows: windows, frontmost: NativeAppTarget.frontmostPID(),
            livePIDs: NativeAppTarget.livePIDs(executablePath:))
    }

    /// Regular apps, plus any other app that shows a normal window on screen
    /// (an accessory app's panel). Windows are layer-0 windows that are on
    /// screen or titled (minimized, other Spaces); untitled offscreen buffers
    /// are internal. LaunchServices entries without a recoverable pid are left out.
    static func entries(_ applications: [NativeAppListApplication], windows: [[String: Any]], frontmost: pid_t?,
                        livePIDs: (String) -> [pid_t]) -> [NativeAppListEntry] {
        var byOwner: [pid_t: [NativeAppListWindow]] = [:]
        for info in windows {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            guard onScreen || title != nil else { continue }
            byOwner[owner, default: []].append(.init(window_id: number, title: title, on_screen: onScreen))
        }
        var seen = Set<pid_t>()
        var result: [NativeAppListEntry] = []
        for application in applications {
            guard let pid = NativeAppTarget.livePID(application.candidate, livePIDs: livePIDs), seen.insert(pid).inserted else { continue }
            let owned = byOwner[pid] ?? []
            guard application.regular || owned.contains(where: \.on_screen) else { continue }
            let name = application.candidate.localizedName
                ?? application.candidate.bundleURL?.deletingPathExtension().lastPathComponent ?? "PID \(pid)"
            result.append(.init(name: name, bundle_id: application.candidate.bundleIdentifier, pid: pid,
                frontmost: pid == frontmost ? true : nil, hidden: application.hidden ? true : nil, windows: owned))
        }
        return result.sorted {
            ($0.frontmost == true) != ($1.frontmost == true) ? $0.frontmost == true
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
