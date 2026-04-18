import SwiftUI

struct PreviewTree: View {
    let nodes: [PreviewNode]

    var body: some View {
        List {
            Section("Preview") {
                ForEach(nodes) { root in
                    TreeRow(node: root, defaultExpanded: true)
                }
            }
        }
        .listStyle(.inset)
    }
}

struct TreeRow: View {
    let node: PreviewNode
    @State private var isExpanded: Bool

    init(node: PreviewNode, defaultExpanded: Bool = true) {
        self.node = node
        self._isExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    TreeRow(node: child, defaultExpanded: false)
                }
            } label: {
                PreviewRow(node: node)
            }
        } else {
            PreviewRow(node: node)
        }
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
