import SwiftUI
import AppKit

/// Open Log / Show in Finder / Export Manifest — for **every** terminal state,
/// not just success.
///
/// A halted or cancelled job still wrote its manifest (marked `partial: true`)
/// and its log, and `IngestEngine` still returned both URLs. Those buttons lived
/// only in `CompletionSheet`, which is presented solely for `.completed`, so the
/// two outcomes where a user most needs to know exactly what landed offered a
/// sentence and a Reset button — while the halt notification told them to "see
/// the app for details" that were not there.
///
/// Taking a `CopyResult?` and rendering nothing when it is nil keeps the call
/// sites honest: a state with no receipt (no photos to copy, or a cancel before
/// the engine finished unwinding) shows no buttons rather than dead ones.
struct JobArtifactButtons: View {
    let result: CopyResult?
    @State private var exportError: String?

    var body: some View {
        if let result {
            HStack(spacing: 10) {
                if let logURL = result.logURL {
                    Button("Open Log") { NSWorkspace.shared.open(logURL) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.primaryDestination])
                }
                if let manifestURL = result.manifestURL {
                    Button("Export Manifest…") { export(manifestURL) }
                }
            }
            .alert("Couldn’t export the manifest", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
        }
    }

    /// The manifest is already written next to the photos; this saves a copy
    /// wherever the user wants.
    private func export(_ manifestURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = manifestURL.lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Export Verification Manifest"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        do {
            // The save panel already confirmed any overwrite; replace the target.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: manifestURL, to: destination)
        } catch {
            // Surface the failure — the user believes a receipt was saved.
            exportError = error.localizedDescription
        }
    }
}
