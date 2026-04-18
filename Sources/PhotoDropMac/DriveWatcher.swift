import Foundation
import AppKit
import Observation

struct DetectedDrive: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let mountPoint: String
    let url: URL
    let totalBytes: Int64
}

@MainActor
@Observable
final class DriveWatcher {
    private(set) var drives: [DetectedDrive] = []

    @ObservationIgnored private nonisolated(unsafe) var mountObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var unmountObserver: (any NSObjectProtocol)?

    init() {
        rescan()
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rescan()
            }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rescan()
            }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let m = mountObserver { center.removeObserver(m) }
        if let u = unmountObserver { center.removeObserver(u) }
    }

    func rescan() {
        drives = Self.scanRemovableDrives()
    }

    private static func scanRemovableDrives() -> [DetectedDrive] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeTotalCapacityKey,
            .volumeUUIDStringKey,
        ]

        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return volumes.compactMap { url -> DetectedDrive? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isLocal = values.volumeIsLocal ?? true
            let isEjectable = values.volumeIsEjectable ?? false
            let isRemovable = values.volumeIsRemovable ?? false
            // Don't filter on `isInternal` — a MacBook Pro's built-in SD reader
            // reports its card as internal even though the media is clearly
            // removable. The ejectable/removable check is sufficient to
            // separate cards from the boot disk.
            guard isLocal, (isEjectable || isRemovable) else {
                return nil
            }
            let label = values.volumeName ?? url.lastPathComponent
            let mountPoint = url.path(percentEncoded: false)
            let id = values.volumeUUIDString ?? mountPoint
            let bytes = Int64(values.volumeTotalCapacity ?? 0)
            return DetectedDrive(
                id: id,
                label: label,
                mountPoint: mountPoint,
                url: url,
                totalBytes: bytes
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
