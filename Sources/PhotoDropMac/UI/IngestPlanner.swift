import Foundation
import Observation

@MainActor
@Observable
final class IngestPlanner {
    private(set) var isScanning: Bool = false
    private(set) var yearGroups: [YearGroup] = []
    /// Folders on the card the scan could not open, and whether the card could be
    /// read at all. The walk used to swallow both: a card jostled loose mid-scan
    /// simply produced fewer bundles, so a 500-photo card could show 137 files
    /// with no error, ingest them, report "✓ Ingest complete" and write a manifest
    /// attesting to the 137. The UI needs to be able to say "this is not all of
    /// it", and the ingest must not eject on the strength of a partial view.
    private(set) var unreadableDirectories: Int = 0
    private(set) var sourceUnreadable: Bool = false

    /// The scan saw the whole card. Gates the auto-eject.
    var scanWasComplete: Bool { !sourceUnreadable && unreadableDirectories == 0 }

    @ObservationIgnored private var bundles: [AssetBundle] = []
    @ObservationIgnored private var lastDescription: String = ""
    @ObservationIgnored private var lastTemplate: NamingTemplate = .default
    @ObservationIgnored private var lastCardLabel: String = ""
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // `totalFiles` includes companions — the UI uses it for the
    // "X files · Y GB" header, which should reflect everything that
    // will be copied, not just primaries.
    var totalFiles: Int { yearGroups.reduce(0) { $0 + $1.totalFiles } }
    var totalBytes: Int64 { yearGroups.reduce(0) { $0 + $1.totalBytes } }

    // Primary-only count, for callers that want "photos" rather than
    // "files on disk" (e.g. the detail subtitle).
    var photoCount: Int { yearGroups.reduce(0) { $0 + $1.bundleCount } }

    func setSource(_ source: DetectedDrive?, description: String, template: NamingTemplate) {
        scanTask?.cancel()
        lastDescription = description
        lastTemplate = template
        lastCardLabel = source?.label ?? ""
        bundles = []
        yearGroups = []
        unreadableDirectories = 0
        sourceUnreadable = false

        guard let source else {
            isScanning = false
            return
        }

        let url = source.url
        isScanning = true

        scanTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                AssetDiscovery.scanOutcome(root: url)
            }.value

            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .unreadableSource:
                self.sourceUnreadable = true
                self.bundles = []
            case let .scanned(bundles, unreadableDirectories):
                self.unreadableDirectories = unreadableDirectories
                self.bundles = bundles
            }
            self.replan()
            self.isScanning = false
        }
    }

    func updateDescription(_ description: String) {
        lastDescription = description
        replan()
    }

    func updateTemplate(_ template: NamingTemplate) {
        lastTemplate = template
        replan()
    }

    private func replan() {
        yearGroups = PathPlanner.plan(bundles: bundles, description: lastDescription, template: lastTemplate, cardLabel: lastCardLabel)
    }
}
