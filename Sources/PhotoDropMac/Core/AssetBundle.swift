import Foundation

// Companion-file classifications recognized by PhotoDrop. The set is
// deliberately closed: anything outside these five kinds (xmp/dop/pp3/aae
// sidecars, JPEG pair, camera audio note) is treated as an unrelated file,
// not a companion.
enum CompanionKind: Sendable, Hashable {
    case xmp       // Adobe-style XMP sidecar (both IMG_1234.xmp and IMG_1234.DNG.xmp variants)
    case dop       // DxO PhotoLab sidecar
    case pp3       // RawTherapee sidecar
    case aae       // Apple Photos adjustment sidecar (IMG_1234.AAE beside IMG_1234.HEIC / .JPG)
    case jpegPair  // JPEG shot next to a RAW with matching stem
    case audioNote // Camera audio memo (.wav adjacent to primary with matching stem)
}

// A single file that travels with an `AssetBundle.primary`. Matched by
// filename in the **same directory** as the primary — cross-directory
// matching is an explicit non-feature.
struct CompanionFile: Sendable, Hashable {
    let url: URL
    let size: Int64
    let kind: CompanionKind
}

// The atomic unit of ingest: one primary photo plus its companions.
// Copy, verification, and the UI all operate on whole bundles — a RAW
// without its .dop has lost its edits, so the two must move together.
struct AssetBundle: Sendable, Hashable, Identifiable {
    let primary: ScannedPhoto
    let companions: [CompanionFile]

    var id: URL { primary.id }

    // Total bytes across the primary and every companion — used by the
    // UI summary and the copy-progress accounting.
    var totalSize: Int64 {
        companions.reduce(primary.size) { $0.saturatingAdding($1.size) }
    }

    // Total file count including the primary and its companions. The UI
    // "X files" label reflects what will actually be copied.
    var fileCount: Int { 1 + companions.count }
}

extension Int64 {
    /// `self + other`, pinned at the bound instead of trapping.
    ///
    /// File sizes come off the card, and Swift traps on overflow: two sparse
    /// files of ~2^62 bytes on an APFS/HFS+ stick, or a forged exFAT
    /// `DataLength`, crashed the app while it was still *planning* — adding up
    /// the preview totals. A byte count that saturates is wrong only for a card
    /// that could never be copied anyway.
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }

    /// `self * other`, pinned at the bound instead of trapping. See `saturatingAdding`.
    func saturatingMultiplied(by other: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) != (other < 0) ? .min : .max) : product
    }
}
