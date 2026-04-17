import SwiftUI

struct PreviewTree: View {
    let nodes: [PreviewNode]

    var body: some View {
        List {
            Section {
                OutlineGroup(nodes, children: \.children) { node in
                    PreviewRow(node: node)
                }
            } header: {
                HStack {
                    Text("Preview")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }
}

struct PreviewRow: View {
    let node: PreviewNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.icon)
                .foregroundStyle(node.isHighlighted ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .fontWeight(node.isHighlighted ? .semibold : .regular)
                    .foregroundStyle(node.isHighlighted ? Color.accentColor : Color.primary)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}
