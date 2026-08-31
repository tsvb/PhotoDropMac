import Foundation
import Observation

/// UI state for the verify flow. The verification work itself lives in the
/// nonisolated `VerifyEngine` (Core); this enum is the controller's view state.
enum VerifyState: Sendable, Equatable {
    case idle
    case running(VerifyProgress)
    case completed(VerifyReport)
    case failed(String)
}

/// Drives `VerifyEngine` off the main actor and reflects its progress/result
/// into observable UI state. A thin wrapper — all the verification logic is in
/// the engine, which the CLI shares.
@MainActor
@Observable
final class Verifier {
    private(set) var state: VerifyState = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = CancellationFlag()

    static let noManifestMessage =
        "No verification manifest found. Run an ingest first, or choose a library folder that contains a “\(ManifestWriter.folderName)” folder."

    /// Why a run checked nothing, distinguishing "there is no record here" from
    /// "there is a record and none of it could be used". Mirrors the CLI's
    /// `xattrNothingChecked`.
    static func nothingToCheckMessage(_ report: VerifyReport) -> String {
        guard report.manifestCount > 0 else { return noManifestMessage }
        var lines = ["\(report.manifestCount) manifest(s) were found, but none of their entries could be checked."]
        if report.undigested > 0 {
            lines.append("\(report.undigested) entr(y/ies) record no checksum — older manifests recorded none for duplicate-skipped files.")
        }
        if report.outOfRoot > 0 {
            lines.append("\(report.outOfRoot) entr(y/ies) name a path outside this library and were refused.")
        }
        return lines.joined(separator: "\n\n")
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func cancel() {
        task?.cancel()
        cancelFlag.cancel()
        if case .running = state { state = .idle }
    }

    func reset() {
        // Retire the generation too, so an in-flight run can't repaint the UI
        // after the user has dismissed it — see `Copier.reset`.
        cancelFlag.cancel()
        cancelFlag = CancellationFlag()
        state = .idle
        task = nil
    }

    func start(target: URL) {
        cancel()                          // abort any in-flight run (trips its flag)
        let flag = CancellationFlag()
        cancelFlag = flag
        state = .running(VerifyProgress(total: 0, checked: 0, currentFile: "Reading manifests…"))

        task = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { [weak self] () -> VerifyReport? in
                var lastTick = Date()
                return VerifyEngine.run(target: target, isCancelled: { flag.isCancelled }) { progress in
                    // Throttle UI updates (~0.1s) and always send the final tick.
                    let now = Date()
                    guard progress.checked == progress.total || now.timeIntervalSince(lastTick) > 0.1 else { return }
                    lastTick = now
                    Task { @MainActor [weak self] in
                        // Guard on flag *identity*, not just `.running`: a
                        // superseded verify is still `.running` (the new one put
                        // it there), so its ticks were overwriting the new run's
                        // progress until its current file finished hashing.
                        guard let self, self.cancelFlag === flag, case .running = self.state else { return }
                        self.state = .running(progress)
                    }
                }
            }.value

            guard let self, !flag.isCancelled else { return }   // cancelled or superseded
            if let report {
                // `total == 0` used to collapse into one message: "no manifest
                // found". It can also mean a manifest was found and *none of it
                // was usable* — every entry carrying no digest (older manifests
                // recorded none for duplicate-skipped files), or every entry
                // resolving outside the library root. Telling a user to "run an
                // ingest first" over a library that has manifests is the same
                // couldn't-check/nothing-there collapse `XattrOutcome` exists to
                // prevent, reintroduced at the GUI layer.
                self.state = report.total == 0
                    ? .failed(Self.nothingToCheckMessage(report))
                    : .completed(report)
            }
        }
    }
}
