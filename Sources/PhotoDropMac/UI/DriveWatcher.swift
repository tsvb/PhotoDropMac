import Foundation
import AppKit
import DiskArbitration
import Observation

/// How a mounted volume's media is backed — the one thing that tells a memory
/// card apart from a mounted disk image.
///
/// A mounted `.dmg` (or `.sparsebundle`, or any `hdiutil attach`ed image) is
/// **local, ejectable and removable**, which is exactly the signature
/// `DriveWatcher` uses to recognise a card: measured on macOS, a read/write
/// HFS+ image, a read-only UDZO image, an APFS image and a sparsebundle all
/// report `isLocal = true, isEjectable = true, isRemovable = true`. So every
/// disk image the user had open — an app installer, a backup, a downloaded ISO
/// — appeared in the card list, auto-opened the window on mount, and was a
/// legal one-click ingest target.
enum VolumeBacking {
    /// True when a DiskArbitration description belongs to a disk image.
    ///
    /// Three independent signals, OR'd, because any one of them can be absent:
    /// the device model and protocol strings macOS gives every image, and the
    /// structural fact underneath them — the media is served by the kernel's
    /// `IOHDIXController` rather than by a bus. No physical card reader
    /// (USB, `Secure Digital`, Thunderbolt) reports any of the three.
    static func isDiskImage(_ description: [String: Any]) -> Bool {
        func string(_ key: CFString) -> String? {
            description[key as String] as? String
        }
        if string(kDADiskDescriptionDeviceModelKey)?
            .trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Disk Image") == .orderedSame { return true }
        if string(kDADiskDescriptionDeviceProtocolKey)?
            .trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Virtual Interface") == .orderedSame { return true }
        if string(kDADiskDescriptionDevicePathKey)?.contains("IOHDIX") == true { return true }
        return false
    }

    /// The description DiskArbitration holds for the volume mounted at `url`,
    /// or `nil` if it has none.
    ///
    /// Callers **fail open** on `nil`: an unreadable description is not
    /// evidence of a disk image, and hiding a real card is the worse error.
    static func description(ofVolumeAt url: URL, session: DASession) -> [String: Any]? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }
        return DADiskCopyDescription(disk) as? [String: Any]
    }
}

struct DetectedDrive: Identifiable, Hashable, Sendable {
    /// What this source is. A folder chosen by the user is offered alongside the
    /// cards because the engine has never cared about the difference — the CLI
    /// has always documented `--from` as "memory card **or source folder**" — and
    /// only the GUI was fenced in. Without it you could not re-file an existing
    /// shoot, ingest a card someone else had already dumped to a drive, re-run an
    /// ingest after the card was pulled, or evaluate the app on your own library.
    ///
    /// The distinction still matters for exactly one thing: a folder is never
    /// ejected. `DriveEjector` runs `diskutil eject` on the *volume* containing
    /// the path, so ejecting a folder source would unmount the disk it lives on —
    /// which, for a folder inside the user's own library, is the startup disk.
    enum Kind: Sendable, Hashable { case card, folder }

    let id: String
    let label: String
    let mountPoint: String
    let url: URL
    let totalBytes: Int64
    var kind: Kind = .card

    var isEjectable: Bool { kind == .card }

    /// A user-chosen folder presented as a source.
    ///
    /// The id is the path rather than a volume UUID: two folders on one volume
    /// are two different sources, and the volume's UUID would make them one.
    static func folder(at url: URL) -> DetectedDrive {
        let standardized = url.standardizedFileURL
        let size = (try? standardized.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize
        return DetectedDrive(
            id: "folder:" + standardized.path,
            label: standardized.lastPathComponent,
            mountPoint: standardized.path,
            url: standardized,
            totalBytes: Int64(size ?? 0),
            kind: .folder
        )
    }
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

        // One session for the whole sweep; used synchronously and dropped here.
        let session = DASessionCreate(kCFAllocatorDefault)

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
            // ...but it is *not* sufficient to separate cards from mounted disk
            // images, which claim the same three flags. See `VolumeBacking`.
            if let session,
               let description = VolumeBacking.description(ofVolumeAt: url, session: session),
               VolumeBacking.isDiskImage(description) {
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
