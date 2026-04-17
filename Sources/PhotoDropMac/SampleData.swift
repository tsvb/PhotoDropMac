import Foundation

struct DetectedDrive: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let mountPoint: String
    let photoCount: Int
    let totalBytes: Int64
}

struct PreviewNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let subtitle: String?
    let icon: String
    let isHighlighted: Bool
    let children: [PreviewNode]?
}

enum Sample {
    static let cards: [DetectedDrive] = [
        DetectedDrive(
            label: "SanDisk Extreme 64 GB",
            mountPoint: "/Volumes/SanDisk Extreme",
            photoCount: 1247,
            totalBytes: 48_300_000_000
        )
    ]

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
