import Foundation

struct PreviewNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let subtitle: String?
    let icon: String
    let isHighlighted: Bool
    let children: [PreviewNode]?
}

enum Sample {
    // Preview tree stays mocked until AssetDiscoveryService is ported — the
    // live DriveWatcher populates real drives, but discovering photos on them
    // (grouping into bundles, planning destination paths) is a later step.
    static let previewTree: [PreviewNode] = [
        PreviewNode(
            name: "2026",
            subtitle: nil,
            icon: "folder",
            isHighlighted: false,
            children: [
                PreviewNode(
                    name: "2026-04-17_Wedding",
                    subtitle: "247 files · 12.8 GB",
                    icon: "folder.fill",
                    isHighlighted: true,
                    children: nil
                ),
                PreviewNode(
                    name: "2026-04-16",
                    subtitle: "103 files · 4.2 GB",
                    icon: "folder.fill",
                    isHighlighted: true,
                    children: nil
                ),
                PreviewNode(
                    name: "2026-04-15",
                    subtitle: "87 files · 3.4 GB",
                    icon: "folder.fill",
                    isHighlighted: true,
                    children: nil
                )
            ]
        )
    ]
}
