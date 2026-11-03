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

/// SwiftUI measures the two text lines first, then proposes that exact height
/// and width to the icon. No font metrics or pixel offsets to keep in sync.
struct TwoLineIconLayout: Layout {
    var spacing: CGFloat = 8 // Matches the existing agent line's icon gap.
    private func textSize(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGSize {
        let ideal = subviews[1].sizeThatFits(.unspecified)
        return subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - ideal.height - spacing) }, height: nil))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let text = textSize(proposal, subviews)
        return CGSize(width: proposal.width ?? text.height + spacing + text.width, height: text.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let text = textSize(ProposedViewSize(width: bounds.width, height: nil), subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: text.height, height: text.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + text.height + spacing, y: bounds.minY), anchor: .topLeading,
                          proposal: .init(width: bounds.width - text.height - spacing, height: text.height))
    }
}

struct TwoLineLabel<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: () -> Icon
    var body: some View {
        TwoLineIconLayout {
            icon()
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct MenuAgentRow<Icon: View, Preview: View>: View {
    let name: String
    let activity: String
    let watchers: [String]
    let disconnect: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var preview: () -> Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TwoLineLabel(title: name, subtitle: activity, icon: icon)
            if let text = StreamWatchers.rowText(watchers) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview()
            HStack {
                Spacer()
                Button("Disconnect", action: disconnect)
            }
        }
    }
}
