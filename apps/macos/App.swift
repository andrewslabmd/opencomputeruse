import SwiftUI
import AppKit
import Darwin
import ServiceManagement

/// A connected agent, as the panel and the window show it.
struct Agent: Identifiable, Equatable {
    let id: String
    let name: String
    /// The app it is working in, when it holds one.
    let app: String?
    /// Its cursor color slot, when it holds an app.
    let slot: Int?
    /// A call is in flight (acting) rather than thinking between calls.
    let busy: Bool
    var color: Color { slot.map { Color(nsColor: AgentCursorView.palette[$0 % AgentCursorView.palette.count]) } ?? .secondary }
    var detail: String {
        guard let app else { return "Connected" }
        return busy ? "Working in \(app)" : "Thinking · \(app)"
    }
}

/// A coding agent as `ocu setup --json` reports it.
struct AgentSetup: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    /// connected, outdated, available, not_installed or error.
    let status: String
    let message: String?
}

@MainActor
final class HostModel: ObservableObject {
    static let shared = HostModel()

    enum Health { case starting, ready, stopped, unavailable }
    @Published var health = Health.starting
    @Published var detail = ""
    @Published var paused = false
    @Published var agents: [Agent] = []
    /// Permission grants of the helper; nil until read.
    @Published var accessibility: Bool?
    @Published var screenRecording: Bool?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var cliInstalled = false
    /// Coding agents and whether each launches this copy of the app; nil until read.
    @Published var agentSetups: [AgentSetup]?
    /// The agent being connected or disconnected, and the last failure per agent.
    @Published var agentSetupBusy: String?
    @Published var agentSetupErrors: [String: String] = [:]
    @Published var hostPID: Int32?
    @Published var showCursors = UserDefaults.standard.object(forKey: "showAgentCursors") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCursors, forKey: "showAgentCursors"); overlay.enabled = showCursors }
    }
    lazy var overlay = CursorOverlay(runtime: runtime)
    /// The menu-bar icon: idle, or animated in the working agents' colors.
    @Published var menuBarImage = MenuBarIcon.make()
    private var workingSlots: [Int] = []
    private var animation: Timer?
    private var helper: Process?
    private var host: Process?
    private var lock: Int32 = -1
    private var timer: Timer?
    private var ticks = 0
    private var hostStarts: [Date] = []
    private let hostError = HostErrorTail()
    let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Open Computer Use")
    var binaries: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS") }
    var resources: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources") }
    var commands: URL { runtime.appendingPathComponent("helper-commands") }
    var cliLink: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ocu") }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    /// What any MCP client runs: a stdio server named opencomputeruse.
    var mcpCommand: String { "\"\(binaries.appendingPathComponent("ocu").path)\" mcp" }
    var workingAgents: [Agent] { agents.filter { $0.app != nil } }
    var permissionsMissing: Bool { accessibility == false || screenRecording == false }

    var statusText: String {
        switch health {
        case .starting: return "Starting…"
        case .unavailable: return "Unavailable"
        case .stopped: return "Stopped"
        case .ready:
            let working = workingAgents.count
            if working > 0 { return working == 1 ? "1 agent working" : "\(working) agents working" }
            return agents.isEmpty ? "Ready" : "Ready · \(agents.count) connected"
        }
    }
    var statusColor: Color {
        switch health {
        case .ready: return .green
        case .stopped: return .orange
        case .starting: return .secondary
        case .unavailable: return .red
        }
    }

    private init() { start() }
    func start() {
        do {
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lock = Darwin.open(runtime.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { health = .unavailable; detail = "Another copy of Open Computer Use is already running."; return }
            try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Remove only our own abandoned request/response files before the helper starts.
            for file in try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("request-") || file.lastPathComponent.hasPrefix("response-") { try? FileManager.default.removeItem(at: file) }
            let native = Process()
            native.executableURL = resources.appendingPathComponent("Open Computer Use Helper.app/Contents/MacOS/ocu-helper")
            native.arguments = ["--parent-pid", String(getpid()), "--command-directory", commands.path]
            native.standardOutput = FileHandle.nullDevice; native.standardError = FileHandle.nullDevice
            try native.run(); helper = native
            hostStarts = []; try launchHost()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            overlay.enabled = showCursors; overlay.start()
            refreshSetup()
        } catch { health = .unavailable; detail = error.localizedDescription; helper?.terminate() }
    }
    func launchHost() throws {
        let engine = Process(); engine.executableURL = binaries.appendingPathComponent("ocu-host")
        var env = ProcessInfo.processInfo.environment
        env["OCU_RUNTIME_DIR"] = runtime.path
        env["OCU_PARENT_PID"] = String(getpid())
        env["OCU_ENGINE_PATH"] = binaries.appendingPathComponent("ocu-engine").path
        env["OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY"] = commands.path
        engine.environment = env; engine.standardOutput = FileHandle.nullDevice
        // Only the host's own messages; its engine's output is discarded.
        let errors = Pipe(); engine.standardError = errors; hostError.reset()
        errors.fileHandleForReading.readabilityHandler = { [hostError] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { hostError.append(data) }
        }
        try engine.run(); host = engine; hostStarts.append(Date())
    }
    // A host that exits by itself (crash, or a previous host still holding the
    // socket) is started again with backoff; repeated failure shows its reason.
    func restartHost() {
        hostStarts = hostStarts.filter { Date().timeIntervalSince($0) < 60 }
        let reason = hostError.lastLine
        guard hostStarts.count < 5 else { health = .unavailable; detail = "The host keeps stopping\(reason.isEmpty ? "" : ": \(reason)"). Choose Restart Services."; return }
        if let last = hostStarts.last, Date().timeIntervalSince(last) < pow(2, Double(hostStarts.count)) { health = .starting; return }
        do { try launchHost(); health = .starting } catch { health = .unavailable; detail = error.localizedDescription }
    }
    func refresh() {
        ticks += 1
        if ticks % 5 == 0 { refreshSetup() }
        guard helper?.isRunning == true else { health = .unavailable; return }
        guard host?.isRunning == true else { overlay.clear(); setWorking([]); hostPID = nil; restartHost(); return }
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("status.json")), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        paused = state["paused"] as? Bool ?? false
        health = paused ? .stopped : .ready
        hostPID = (state["pid"] as? NSNumber)?.int32Value
        // Each agent works in at most one app at a time.
        var workflows: [String: (app: String, slot: Int?, busy: Bool)] = [:]
        for workflow in state["workflows"] as? [[String: Any]] ?? [] {
            guard let client = workflow["client"] as? String, let pid = (workflow["app_pid"] as? NSNumber)?.int32Value else { continue }
            workflows[client] = (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)",
                (workflow["slot"] as? NSNumber)?.intValue, workflow["busy"] as? Bool ?? false)
        }
        // Working: any agent holds an app, thinking or acting.
        setWorking(workflows.values.compactMap(\.slot).sorted())
        let next = (state["clients"] as? [[String: Any]] ?? []).compactMap { client -> Agent? in
            guard let id = client["id"] as? String else { return nil }
            let name = client["name"] as? String ?? "Agent"
            // The app's own command-line connections are not agents.
            if name == "CLI" { return nil }
            let workflow = workflows[id]
            return Agent(id: id, name: name, app: workflow?.app, slot: workflow?.slot, busy: workflow?.busy ?? false)
        }
        if next != agents { agents = next }
    }
    /// Permissions, open at login and the command-line tool: things that change rarely.
    func refreshSetup() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        cliInstalled = (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) == binaries.appendingPathComponent("ocu").path
        Task {
            guard let response = await helperRequest("permissionStatus"), let stdout = response["stdout"] as? String,
                  let list = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [[String: Any]] else { return }
            let granted = { (name: String) in list.first { $0["name"] as? String == name }?["isGranted"] as? Bool }
            accessibility = granted("Accessibility"); screenRecording = granted("Screen Recording")
        }
    }
    /// A request to the signed helper through its private command directory.
    func helperRequest(_ action: String) async -> [String: Any]? {
        let id = UUID().uuidString
        let request = commands.appendingPathComponent("request-\(id).json"), response = commands.appendingPathComponent("response-\(id).json")
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "action": action]), (try? data.write(to: request, options: .atomic)) != nil else { return nil }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let data = try? Data(contentsOf: response), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(at: response); return object
            }
        }
        try? FileManager.default.removeItem(at: request)
        return nil
    }
    /// Animates the menu-bar ripple while any agent works; several agents alternate colors per pulse.
    func setWorking(_ slots: [Int]) {
        guard slots != workingSlots else { return }
        workingSlots = slots
        animation?.invalidate(); animation = nil
        guard !slots.isEmpty else { menuBarImage = MenuBarIcon.make(); return }
        let start = Date()
        func frame() {
            let elapsed = Date().timeIntervalSince(start), pulses = elapsed / MenuBarIcon.period
            let slot = workingSlots[Int(pulses) % max(workingSlots.count, 1)]
            menuBarImage = MenuBarIcon.make(color: AgentCursorView.palette[slot % AgentCursorView.palette.count], phase: CGFloat(pulses - floor(pulses)))
        }
        frame()
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in MainActor.assumeIsolated { frame() } }
    }

    // MARK: Actions
    func stop() { command(["stop"]) }
    func resume() { command(["resume"]) }
    func disconnect(_ agent: Agent) { command(["revoke", agent.id]) }
    func command(_ args: [String]) {
        Task {
            do { detail = try await runCLI(args); refresh() }
            catch { detail = error.localizedDescription }
        }
    }
    func runCLI(_ args: [String]) async throws -> String {
        let executable = binaries.appendingPathComponent("ocu")
        return try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = args
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
    /// Asks macOS for the permission on the helper's behalf (it shows its prompt or Settings).
    func requestPermission(_ action: String) {
        guard ["accessibility", "screenRecording"].contains(action) else { return }
        Task { _ = await helperRequest(action); refreshSetup() }
    }
    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func copyMCPCommand() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcpCommand, forType: .string)
    }
    /// Reads every agent's state through `ocu setup`, the same code the command line uses.
    func refreshAgentSetups() {
        Task {
            struct Report: Decodable { let agents: [AgentSetup] }
            guard let output = try? await runCLI(["setup", "--json"]),
                  let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)) else { return }
            if report.agents != agentSetups { agentSetups = report.agents }
        }
    }
    func setUpAgent(_ id: String, remove: Bool = false) {
        agentSetupBusy = id; agentSetupErrors[id] = nil
        Task {
            let output = (try? await runCLI(["setup", id, "--json"] + (remove ? ["--remove"] : []))) ?? ""
            if (try? JSONDecoder().decode(AgentSetup.self, from: Data(output.utf8))) == nil {
                agentSetupErrors[id] = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "error: ", with: "")
            }
            agentSetupBusy = nil
            refreshAgentSetups()
        }
    }
    func installCLI() {
        let directory = cliLink.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cliLink.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) != nil {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) == binaries.appendingPathComponent("ocu").path else { detail = "An unrelated ocu command exists at ~/.local/bin/ocu; it was left alone."; return }
            } else { try FileManager.default.createSymbolicLink(at: cliLink, withDestinationURL: binaries.appendingPathComponent("ocu")) }
            detail = "Installed ~/.local/bin/ocu. Add ~/.local/bin to PATH if needed."
        } catch { detail = error.localizedDescription }
        refreshSetup()
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { detail = error.localizedDescription }
        refreshSetup()
    }
    func revealRuntime() { NSWorkspace.shared.activateFileViewerSelecting([runtime]) }
    func repair() {
        timer?.invalidate(); overlay.clear(); host?.terminate(); helper?.terminate()
        let children = [host, helper].compactMap { $0 }
        Task {
            await Task.detached {
                let deadline = Date(timeIntervalSinceNow: 4)
                while children.contains(where: { $0.isRunning }) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                for child in children where child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }.value
            if lock >= 0 { Darwin.close(lock); lock = -1 }
            host = nil; helper = nil; start()
        }
    }
    func quit() {
        timer?.invalidate(); overlay.clear(); host?.terminate(); helper?.terminate()
        let children = [host, helper].compactMap { $0 }
        Task {
            await Task.detached {
                let deadline = Date(timeIntervalSinceNow: 4)
                while children.contains(where: { $0.isRunning }) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                for child in children where child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }.value
            if lock >= 0 { Darwin.close(lock) }; NSApp.terminate(nil)
        }
    }
}

/// Keeps running when the window closes, and opens the window when the app is
/// launched again while running (from Spotlight, Finder or the Dock), which is
/// the way in when the menu-bar icon is hidden by the notch or other items.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
        return true
    }
}

@main
struct ComputerUseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HostModel.shared
    var body: some Scene {
        // The one window, in the style of System Settings. Not opened at launch;
        // the panel, a second launch of the app, or Settings… opens it.
        Window("Open Computer Use", id: SettingsWindow.id) {
            SettingsView(model: model, selection: SettingsWindow.shared.selection)
        }
        .defaultSize(width: 780, height: 600)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(image: model.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar icon. It is on screen from launch, so it also hands SwiftUI's
/// window opener to AppKit code (the reopen handler, the panel's buttons).
struct MenuBarLabel: View {
    let image: NSImage
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(nsImage: image)
            .onAppear { SettingsWindow.shared.open = { openWindow(id: SettingsWindow.id) } }
    }
}

/// The end of the host's error output, written from a pipe reader thread.
final class HostErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func reset() { lock.lock(); data = Data(); lock.unlock() }
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); if data.count > 4096 { data = data.suffix(4096) }; lock.unlock() }
    var lastLine: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}
