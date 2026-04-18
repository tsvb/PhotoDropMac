import Foundation
import Observation

@MainActor
@Observable
final class IngestPlanner {
    private(set) var isScanning: Bool = false
    private(set) var yearGroups: [YearGroup] = []

    @ObservationIgnored private var bundles: [AssetBundle] = []
    @ObservationIgnored private var lastDescription: String = ""
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // `totalFiles` includes companions — the UI uses it for the
    // "X files · Y GB" header, which should reflect everything that
    // will be copied, not just primaries.
    var totalFiles: Int { yearGroups.reduce(0) { $0 + $1.totalFiles } }
    var totalBytes: Int64 { yearGroups.reduce(0) { $0 + $1.totalBytes } }

    // Primary-only count, for callers that want "photos" rather than
    // "files on disk" (e.g. the detail subtitle).
    var photoCount: Int { yearGroups.reduce(0) { $0 + $1.bundleCount } }

    func setSource(_ source: DetectedDrive?, description: String) {
        scanTask?.cancel()
        lastDescription = description
        bundles = []
        yearGroups = []

        guard let source else {
            isScanning = false
            return
        }

        let url = source.url
        isScanning = true

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AssetDiscovery.scan(root: url)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.bundles = result
            self.yearGroups = PathPlanner.plan(bundles: result, description: self.lastDescription)
            self.isScanning = false
        }
    }

    func updateDescription(_ description: String) {
        lastDescription = description
        yearGroups = PathPlanner.plan(bundles: bundles, description: description)
    }
}
