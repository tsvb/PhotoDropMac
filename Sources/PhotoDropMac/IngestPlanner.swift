import Foundation
import Observation

@MainActor
@Observable
final class IngestPlanner {
    private(set) var isScanning: Bool = false
    private(set) var yearGroups: [YearGroup] = []

    @ObservationIgnored private var photos: [ScannedPhoto] = []
    @ObservationIgnored private var lastDescription: String = ""
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var totalFiles: Int { yearGroups.reduce(0) { $0 + $1.totalFiles } }
    var totalBytes: Int64 { yearGroups.reduce(0) { $0 + $1.totalBytes } }

    func setSource(_ source: DetectedDrive?, description: String) {
        scanTask?.cancel()
        lastDescription = description
        photos = []
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
            self.photos = result
            self.yearGroups = PathPlanner.plan(photos: result, description: self.lastDescription)
            self.isScanning = false
        }
    }

    func updateDescription(_ description: String) {
        lastDescription = description
        yearGroups = PathPlanner.plan(photos: photos, description: description)
    }
}
