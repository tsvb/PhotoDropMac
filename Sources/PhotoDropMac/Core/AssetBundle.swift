import Foundation

// Companion-file classifications recognized by PhotoDrop. The set is
// deliberately closed: anything outside these four kinds (xmp/dop/pp3
// sidecars, JPEG pair, camera audio note) is treated as an unrelated file,
// not a companion.
enum CompanionKind: Sendable, Hashable {
    case xmp       // Adobe-style XMP sidecar (both IMG_1234.xmp and IMG_1234.DNG.xmp variants)
    case dop       // DxO PhotoLab sidecar
    case pp3       // RawTherapee sidecar
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
        companions.reduce(primary.size) { $0 + $1.size }
    }

    // Total file count including the primary and its companions. The UI
    // "X files" label reflects what will actually be copied.
    var fileCount: Int { 1 + companions.count }
}
