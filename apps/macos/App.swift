import SwiftUI
import AppKit
import Darwin
import ServiceManagement

@MainActor
final class HostModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var detail = ""
    @Published var paused = false
    @Published var clients: [[String: String]] = []
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
    private var hostStarts: [Date] = []
    private let hostError = HostErrorTail()
    let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenComputerUse Dev")
    var binaries: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS") }
    var resources: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources") }

    init() { start() }
    func start() {
        do {
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lock = Darwin.open(runtime.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { status = "Already running"; return }
            let commands = runtime.appendingPathComponent("helper-commands")
            try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Remove only our own abandoned request/response files before the helper starts.
            for file in try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("request-") || file.lastPathComponent.hasPrefix("response-") { try? FileManager.default.removeItem(at: file) }
            let native = Process()
            native.executableURL = resources.appendingPathComponent("OpenComputerUse Helper.app/Contents/MacOS/ocu-helper")
            native.arguments = ["--parent-pid", String(getpid()), "--command-directory", commands.path]
            native.standardOutput = FileHandle.nullDevice; native.standardError = FileHandle.nullDevice
            try native.run(); helper = native
            hostStarts = []; try launchHost()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            overlay.enabled = showCursors; overlay.start()
            status = "Ready"
        } catch { status = "Unavailable"; detail = error.localizedDescription; helper?.terminate() }
    }
    func launchHost() throws {
        let commands = runtime.appendingPathComponent("helper-commands")
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
        guard hostStarts.count < 5 else { status = "Unavailable"; detail = "The host keeps stopping\(reason.isEmpty ? "" : ": \(reason)"). Choose Restart Services."; return }
        if let last = hostStarts.last, Date().timeIntervalSince(last) < pow(2, Double(hostStarts.count)) { status = "Starting…"; return }
        do { try launchHost(); status = "Starting…" } catch { status = "Unavailable"; detail = error.localizedDescription }
    }
    func refresh() {
        guard helper?.isRunning == true else { status = "Unavailable"; return }
        guard host?.isRunning == true else { overlay.clear(); setWorking([]); restartHost(); return }
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("status.json")), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        paused = state["paused"] as? Bool ?? false
        status = paused ? "Stopped" : ((state["busy"] as? Bool == true) ? "Working" : "Ready")
        // Each agent works in at most one app at a time; show which.
        var apps: [String: String] = [:], slots: [String: String] = [:]
        for workflow in state["workflows"] as? [[String: Any]] ?? [] {
            guard let client = workflow["client"] as? String, let pid = (workflow["app_pid"] as? NSNumber)?.int32Value else { continue }
            apps[client] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
            if let slot = (workflow["slot"] as? NSNumber)?.intValue { slots[client] = String(slot) }
        }
        // Working: any agent holds an app, thinking or acting.
        setWorking((state["workflows"] as? [[String: Any]] ?? []).compactMap { ($0["slot"] as? NSNumber)?.intValue }.sorted())
        clients = (state["clients"] as? [[String: Any]] ?? []).map {
            let id = $0["id"] as? String ?? ""
            return ["id": id, "name": $0["name"] as? String ?? "Client", "app": apps[id] ?? "", "slot": slots[id] ?? ""]
        }
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
    func command(_ args: [String]) {
        Task {
            do {
                let output = try await runCLI(args)
                detail = output; refresh()
            } catch { detail = error.localizedDescription }
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
    func permission(_ action: String) {
        guard ["accessibility", "screenRecording"].contains(action) else { return }
        let directory = runtime.appendingPathComponent("helper-commands")
        let id = UUID().uuidString
        do { let data = try JSONSerialization.data(withJSONObject: ["id": id, "action": action]); try data.write(to: directory.appendingPathComponent("request-\(id).json"), options: .atomic); detail = "Complete the permission request in macOS Settings, then check permissions." }
        catch { detail = error.localizedDescription }
    }
    func installCLI() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = directory.appendingPathComponent("ocu")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: link.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == binaries.appendingPathComponent("ocu").path else { detail = "An unrelated ocu command exists; it was preserved."; return }
            } else { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binaries.appendingPathComponent("ocu")) }
            detail = "Installed ~/.local/bin/ocu. Add ~/.local/bin to PATH if needed."
        } catch { detail = error.localizedDescription }
    }
    func login(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; detail = "Login setting updated." }
        catch { detail = error.localizedDescription }
    }
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

@main
struct ComputerUseApp: App {
    @StateObject private var model = HostModel()
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenComputerUse · Development").font(.headline)
                Text(model.status)
                HStack { Button("Stop") { model.command(["stop"]) }; Button("Resume") { model.command(["resume"]) } }
                Toggle("Show agent cursors", isOn: $model.showCursors)
                Divider()
                Button("Allow Accessibility…") { model.permission("accessibility") }
                Button("Allow Screen Recording…") { model.permission("screenRecording") }
                Button("Check Permissions") { model.command(["permissions"]) }
                Button("Restart Services") { model.repair() }
                Button("Install CLI") { model.installCLI() }
                Button("Claude MCP Setup") { model.command(["setup", "claude"]) }
                Menu("Launch at Login") { Button("Enable") { model.login(true) }; Button("Disable") { model.login(false) } }
                ForEach(model.clients, id: \.self) { client in
                    HStack {
                        // The same color as this agent's on-screen cursor.
                        if let slot = Int(client["slot"] ?? "") {
                            Circle().fill(Color(nsColor: AgentCursorView.palette[slot % AgentCursorView.palette.count])).frame(width: 8, height: 8)
                        }
                        VStack(alignment: .leading) {
                            Text(client["name"] ?? "Client")
                            if let app = client["app"], !app.isEmpty { Text("Working in \(app)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Button("Disconnect") { model.command(["revoke", client["id"] ?? ""]) }
                    }
                }
                if !model.detail.isEmpty { ScrollView { Text(model.detail).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 150) }
                Divider()
                Button("Quit") { model.quit() }
            }.padding().frame(width: 380)
        } label: {
            Image(nsImage: model.menuBarImage)
        }.menuBarExtraStyle(.window)
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
