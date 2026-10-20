import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case overview = "Overview", agents = "Agents", permissions = "Permissions", connect = "Connect an Agent", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .agents: return "person.2"
        case .permissions: return "lock.shield"
        case .connect: return "link"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// Opens the Settings window scene from anywhere, at a chosen pane.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let id = "settings"
    let selection = PaneSelection()
    var open: (() -> Void)?

    func show(_ pane: SettingsPane? = nil) {
        if let pane { selection.pane = pane }
        NSApp.activate()
        open?()
    }
}

final class PaneSelection: ObservableObject {
    @Published var pane: SettingsPane? = .overview
}

struct SettingsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var selection: PaneSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.pane) {
                ForEach([SettingsPane.overview, .agents, .permissions]) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                Section("Setup") { Label(SettingsPane.connect.rawValue, systemImage: SettingsPane.connect.symbol).tag(SettingsPane.connect) }
                Section("Advanced") { Label(SettingsPane.diagnostics.rawValue, systemImage: SettingsPane.diagnostics.symbol).tag(SettingsPane.diagnostics) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            switch selection.pane ?? .overview {
            case .overview: OverviewPane(model: model)
            case .agents: AgentsPane(model: model)
            case .permissions: PermissionsPane(model: model)
            case .connect: ConnectPane(model: model)
            case .diagnostics: DiagnosticsPane(model: model)
            }
        }
    }
}

private struct StatusLine: View {
    @ObservedObject var model: HostModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.statusColor).frame(width: 8, height: 8)
            Text(model.statusText).foregroundStyle(.secondary)
        }
    }
}

private struct AgentLine: View {
    let agent: Agent
    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: agent, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                Text(agent.activity).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OverviewPane: View {
    @ObservedObject var model: HostModel
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if model.paused {
                        Button("Resume") { model.resume() }
                    } else {
                        Button("Stop All Agents", role: .destructive) { model.stop() }.disabled(model.health != .ready)
                    }
                } label: {
                    Label {
                        Text("Open Computer Use")
                        StatusLine(model: model)
                    } icon: {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    }
                }
            } footer: {
                if model.paused { Text("Stopped. Agents can't observe or act until you resume.") }
            }
            if model.permissionsMissing {
                Section {
                    LabeledContent {
                        Button("Review…") { SettingsWindow.shared.show(.permissions) }
                    } label: {
                        Label("Permissions needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            // Lists agents holding an app, like the menu panel; an idle
            // connection is not shown, so the header can't say "Connected".
            Section("Agents") {
                if model.agents.isEmpty {
                    LabeledContent("No agent is controlling your computer") { Button("Connect an Agent…") { SettingsWindow.shared.show(.connect) } }
                } else {
                    ForEach(model.agents) { agent in
                        AgentLine(agent: agent)
                    }
                }
            }
            Section("Preferences") {
                Toggle("Show agent cursors", isOn: $model.showCursors)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            if updater.isConfigured {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    LabeledContent("Version \(model.version)") { Button("Check for Updates…") { updater.check() } }
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Overview")
    }
}

private struct AgentsPane: View {
    @ObservedObject var model: HostModel
    var body: some View {
        Form {
            Section {
                if model.agents.isEmpty {
                    LabeledContent("No agent is controlling your computer") { Button("Connect an Agent…") { SettingsWindow.shared.show(.connect) } }
                } else {
                    ForEach(model.agents) { agent in
                        LabeledContent {
                            HStack(spacing: 12) {
                                if let usage = agent.usage { Text(usage).foregroundStyle(.secondary) }
                                Button("Disconnect") { model.disconnect(agent) }
                            }
                        } label: { AgentLine(agent: agent) }
                    }
                }
            } footer: {
                Text("Each agent works in one app at a time, with its own cursor color. An agent can't use an app another agent is working in. Disconnecting ends that agent's connection; it can connect again.")
                    
            }
        }
        .formStyle(.grouped).navigationTitle("Agents")
    }
}

private struct PermissionsPane: View {
    @ObservedObject var model: HostModel
    var body: some View {
        Form {
            Section {
                row("Accessibility", "Read and operate the controls of the apps agents use.", model.accessibility, request: "accessibility", pane: "Privacy_Accessibility")
                row("Screen Recording", "Capture the windows of the app an agent asks to see.", model.screenRecording, request: "screenRecording", pane: "Privacy_ScreenCapture")
            } footer: {
                Text("In System Settings, turn on Open Computer Use. Already on and still not allowed? Choose Fix: it removes the old entry and asks again, then turn it on once more. Agents never get your physical pointer or keyboard, and the app you're using stays in front.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).navigationTitle("Permissions")
    }
    private func row(_ title: String, _ detail: String, _ granted: Bool?, request: String, pane: String) -> some View {
        LabeledContent {
            switch granted {
            case true?: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?:
                HStack {
                    Button("Allow…") { model.requestPermission(request) }
                    Button("Fix") { model.resetPermission(request) }
                        .help("Already on in System Settings? Removes the old entry and asks again.")
                    Button("Open Settings") { model.openPrivacySettings(pane) }
                }
            case nil: ProgressView().controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct ConnectPane: View {
    @ObservedObject var model: HostModel
    @State private var copied = false
    private var installed: [AgentSetup] { model.agentSetups?.filter { $0.status != "not_installed" } ?? [] }
    private var missing: [AgentSetup] { model.agentSetups?.filter { $0.status == "not_installed" } ?? [] }
    var body: some View {
        Form {
            Section {
                if model.agentSetups == nil {
                    LabeledContent("Looking for coding agents…") { ProgressView().controlSize(.small) }
                } else if installed.isEmpty {
                    Text("No supported coding agent was found on this Mac.")
                } else {
                    ForEach(installed) { agent in AgentSetupRow(model: model, agent: agent) }
                }
            } header: { Text("Coding Agents") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("After connecting an agent, restart it or start a new session.")
                    if !missing.isEmpty { Text("Also supported: \(missing.map(\.name).joined(separator: ", ")).") }
                }
                .foregroundStyle(.secondary)
            }
            Section {
                Text(model.mcpCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(copied ? "Copied" : "Copy Command") {
                        model.copyMCPCommand(); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                }
            } header: { Text("Other MCP Clients") } footer: {
                Text("Add a stdio MCP server named opencomputeruse that runs this command. `ocu setup --print` shows the settings for each agent.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("ocu") {
                    if model.cliInstalled { Label("Installed in ~/.local/bin", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Install") { model.installCLI() } }
                }
            } header: { Text("Command-line tool") } footer: {
                Text("For scripts and terminals: `ocu setup`, `ocu status`, `ocu apps`, `ocu observe`, `ocu stop`.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).navigationTitle("Connect an Agent")
        .onAppear { model.refreshAgentSetups() }
    }
}

private struct AgentSetupRow: View {
    @ObservedObject var model: HostModel
    let agent: AgentSetup
    private var detail: String? {
        if let error = model.agentSetupErrors[agent.id] { return error }
        switch agent.status {
        case "outdated": return "Uses another copy of Open Computer Use"
        case "error": return agent.message
        default: return nil
        }
    }
    var body: some View {
        LabeledContent {
            if model.agentSetupBusy == agent.id {
                ProgressView().controlSize(.small)
            } else {
                switch agent.status {
                case "connected":
                    HStack(spacing: 12) {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { model.setUpAgent(agent.id, remove: true) }
                    }
                case "outdated": Button("Update") { model.setUpAgent(agent.id) }
                case "available": Button("Connect") { model.setUpAgent(agent.id) }
                default: EmptyView()
                }
            }
        } label: {
            Text(agent.name)
            if let detail { Text(detail) }
        }
        .disabled(model.agentSetupBusy != nil && model.agentSetupBusy != agent.id)
    }
}

private struct DiagnosticsPane: View {
    @ObservedObject var model: HostModel
    var body: some View {
        Form {
            Section("Services") {
                LabeledContent("Status") { StatusLine(model: model) }
                LabeledContent("Host process") { Text(model.hostPID.map(String.init) ?? "Not running").foregroundStyle(.secondary) }
                LabeledContent("Version") { Text(model.version).foregroundStyle(.secondary) }
                HStack {
                    Button("Show Runtime Folder") { model.revealRuntime() }
                    Spacer()
                    Button("Restart Services") { model.repair() }
                }
            }
            if !model.detail.isEmpty {
                Section("Last message") {
                    ScrollView { Text(model.detail).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Diagnostics")
    }
}
