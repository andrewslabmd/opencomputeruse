import AppKit
import Darwin

// Resolves an application target ("pid:N", "N", bundle ID, name or bundle file
// name) to a live process. LaunchServices can list an application with process
// ID -1 while its process runs (Xcode's embedded Device Hub does); such entries
// are recovered by the bundle executable's path and never returned as-is.
struct NativeAppCandidate: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
    let executableURL: URL?

    init(pid: pid_t, bundleIdentifier: String?, localizedName: String?, bundleURL: URL?, executableURL: URL?) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.localizedName = localizedName
        self.bundleURL = bundleURL; self.executableURL = executableURL
    }

    init(_ application: NSRunningApplication) {
        self.init(pid: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName, bundleURL: application.bundleURL,
            executableURL: application.executableURL
                ?? application.bundleURL.flatMap { Bundle(url: $0)?.executableURL })
    }
}

enum NativeAppTarget {
    static func resolve(_ rawTarget: String) -> pid_t? {
        let candidates = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(NativeAppCandidate.init)
        return resolve(rawTarget, candidates: candidates, livePIDs: livePIDs(executablePath:))
    }

    static func resolve(_ rawTarget: String, candidates: [NativeAppCandidate],
                        livePIDs: (String) -> [pid_t]) -> pid_t? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.lowercased().hasPrefix("pid:") {
            return pid_t(target.dropFirst(4)).flatMap { $0 > 0 ? $0 : nil }
        }
        if let processID = pid_t(target) { return processID > 0 ? processID : nil }
        guard !target.isEmpty else { return nil }
        let name = target.lowercased().hasSuffix(".app") ? String(target.dropLast(4)) : target
        func same(_ value: String?, _ expected: String) -> Bool {
            value?.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let tiers: [(NativeAppCandidate) -> Bool] = [
            { $0.bundleIdentifier == target },
            { same($0.localizedName, name) },
            { same($0.bundleURL?.deletingPathExtension().lastPathComponent, name) },
        ]
        for matches in tiers {
            let matched = candidates.filter(matches)
            if let live = matched.first(where: { $0.pid > 0 }) { return live.pid }
            for candidate in matched { if let processID = livePID(candidate, livePIDs: livePIDs) { return processID } }
        }
        return nil
    }

    // The frontmost application can be one of those pid -1 entries too. Callers
    // watch or compare it, so an unrecoverable pid is reported as unknown (nil).
    static func frontmostPID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        if application.processIdentifier > 0 { return application.processIdentifier }
        return livePID(NativeAppCandidate(application), livePIDs: livePIDs(executablePath:))
    }

    static func livePID(_ candidate: NativeAppCandidate, livePIDs: (String) -> [pid_t]) -> pid_t? {
        if candidate.pid > 0 { return candidate.pid }
        guard let path = candidate.executableURL?.resolvingSymlinksInPath().path else { return nil }
        return livePIDs(path).filter { $0 > 0 }.min()
    }

    // Processes of this user whose executable is exactly `executablePath`.
    static func livePIDs(executablePath: String) -> [pid_t] {
        let expected = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        var capacity = max(proc_listallpids(nil, 0), 0) + 64
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        capacity = min(count, capacity)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(capacity)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  String(cString: buffer) == expected,
                  let identity = try? NativeProcessIdentity.read(pid), identity.uid == getuid()
            else { return false }
            return true
        }
    }
}
