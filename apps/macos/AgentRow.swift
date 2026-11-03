import SwiftUI
import OCUStream

/// Shared row text for the menu panel and Settings → Agents.
struct AgentRowText: View {
    let name: String
    let activity: String
    let watchers: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(activity).font(.caption).foregroundStyle(.secondary)
            if let text = StreamWatchers.rowText(watchers) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MenuAgentRow<Icon: View>: View {
    let name: String
    let activity: String
    let watchers: [String]
    let hasApp: Bool
    let watch: () -> Void
    let disconnect: () -> Void
    @ViewBuilder var icon: () -> Icon
    var body: some View {
        LabeledContent {
            HStack {
                if hasApp { Button("Watch", action: watch) }
                Button("Disconnect", action: disconnect)
            }
        } label: {
            Label {
                AgentRowText(name: name, activity: activity, watchers: watchers)
            } icon: { icon() }
        }
    }
}
