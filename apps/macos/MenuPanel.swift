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
                    TwoLineLabel(title: "Open Computer Use", subtitle: model.statusText) {
                        Image(nsImage: NSApp.applicationIconImage).resizable()
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
                        MenuAgentRow(name: agent.name, activity: agent.activity, watchers: agent.watchers,
                                     disconnect: { model.disconnect(agent) }) {
                            AgentIcon(agent: agent, size: nil)
                        } preview: {
                            if agent.app != nil {
                                AgentPreviewRow(preview: model.panelPreviews.preview(for: agent))
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
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelVisibility { model.panelPreviews.setPanelOpen($0) })
    }
}
