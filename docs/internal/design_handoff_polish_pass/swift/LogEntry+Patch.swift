//
//  LogEntry+Patch.swift
//  PhotoDropMac
//
//  REFERENCE FILE — do not add directly. Apply these changes to your existing
//  `LogEntry` declaration in Copier.swift (or wherever it currently lives).
//  Kept here so the diff is reviewable in isolation.
//

import Foundation

extension LogEntry {
    // MARK: - Add a `signature` field to LogEntry
    //
    // Existing declaration looks roughly like:
    //
    //     struct LogEntry: Identifiable, Sendable {
    //         let id = UUID()
    //         let timestamp: Date
    //         let kind: Kind
    //         let message: String
    //     }
    //
    // Change to:
    //
    //     struct LogEntry: Identifiable, Sendable {
    //         let id = UUID()
    //         let timestamp: Date
    //         let kind: Kind
    //         let message: String
    //         let signature: UInt64?     // NEW
    //
    //         enum Kind: Sendable {
    //             case info, copied, verified, skipped, error
    //         }
    //     }
    //
    // The `signature` is non-nil only on `.verified` rows. All call sites
    // that build a LogEntry must pass `signature:` — Swift will surface them
    // at compile time.
}

// MARK: - Convenience builders
//
// Optional sugar — add these to keep call sites tidy. Drop them in
// Copier.swift below the LogEntry declaration.

extension LogEntry {
    static func info(_ message: String) -> Self {
        .init(timestamp: .now, kind: .info, message: message, signature: nil)
    }

    static func copied(_ message: String) -> Self {
        .init(timestamp: .now, kind: .copied, message: message, signature: nil)
    }

    static func verified(_ message: String, hash: UInt64) -> Self {
        .init(timestamp: .now, kind: .verified, message: message, signature: hash)
    }

    static func skipped(_ message: String) -> Self {
        .init(timestamp: .now, kind: .skipped, message: message, signature: nil)
    }

    static func error(_ message: String) -> Self {
        .init(timestamp: .now, kind: .error, message: message, signature: nil)
    }
}

// MARK: - Call-site examples after the patch
//
//     log.append(.info("Starting ingest: \(bundles.count) bundles, \(totalSize)"))
//     log.append(.info("Indexing destination for duplicates…"))
//
//     // …in verify():
//     log.append(.verified("\(source.name) → \(dest.name)", hash: verifiedHash))
//
//     // …in copier.dedup():
//     log.append(.skipped("\(source.name) — already present as \(existing.name)"))
//
//     // …in error path:
//     log.append(.error("Verify mismatch on \(source.name) — destination copy deleted"))
