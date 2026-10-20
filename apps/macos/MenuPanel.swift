import SwiftUI
import AppKit

// The menu-bar panel: a quick glance built only from standard SwiftUI form
// components, so macOS draws every section, row and control itself. Status and
// Stop, a permission warning only when something is missing, the connected
// agents, and the way into the Settings window. The agent cursor switch lives
// in Settings: it is set once, not checked at a glance.
struct MenuPanel: View {
    @ObservedObject var model: HostModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if model.paused {
                        Button("Resume") { model.resume() }
                    } else {
                        Button("Stop", role: .destructive) { model.stop() }
                            .disabled(model.health != .ready)
                            .help("Stop every agent now")
                    }
                } label: {
                    Label {
                        Text("Open Computer Use")
                        Text(model.statusText)
                    } icon: {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                    }
                }
            }
            if model.permissionsMissing {
                Section {
                    LabeledContent {
                        Button("Review…") { SettingsWindow.shared.show(.permissions) }
                    } label: {
                        Text("Permissions needed")
                        Text("Agents can't see or use apps until you allow them.")
                    }
                }
            }
            Section {
                if model.agents.isEmpty {
                    LabeledContent("No agent is controlling your computer") {
                        Button("Connect…") { SettingsWindow.shared.show(.connect) }
                    }
                } else {
                    ForEach(model.agents) { agent in
                        LabeledContent {
                            Button("Disconnect") { model.disconnect(agent) }
                        } label: {
                            Label {
                                Text(agent.name)
                                Text(agent.activity)
                            } icon: {
                                AgentIcon(agent: agent, size: 24)
                            }
                        }
                    }
                }
            } header: {
                Text("Agents")
            }
            // A row of its own, not a footer: footers are inset to the row text,
            // so the buttons would not line up with the sections above.
            Section {
                HStack {
                    Button("Settings…") { SettingsWindow.shared.show() }
                    Spacer()
                    Button("Quit") { model.quit() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}
