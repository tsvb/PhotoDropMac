import Foundation
import Darwin

// Pure-Swift xxHash64 (XXH64), per Yann Collet's specification at
// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
//
// This is a non-cryptographic 64-bit hash used by PhotoDropMac to verify that
// a file copied from a source card onto the destination library is byte-for-byte
// identical to what was read. Designed to be teed during the copy so multi-GB
// files are only read once: the copy pipeline feeds each 1 MiB chunk it writes
// into `update(_:)` and compares the resulting digest against a digest computed
// the same way on the source.
//
// Value semantics + no shared state => trivially Sendable under Swift 6.

struct XxHash64: Sendable {
    // XXH64 primes, straight from the reference implementation.
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    private let seed: UInt64

    // Four parallel accumulators, initialised from the seed on first use of the
    // 32-byte-stripe path. We defer initialisation (and the "have we seen >=32
    // bytes total" flag) to correctly handle small inputs, which skip the
    // stripe path and run a different finalisation.
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64

    // Buffer holding leftover bytes that don't yet fill a full 32-byte stripe.
    // Sized to exactly one stripe; content beyond `bufferCount` is undefined.
    private var buffer: (UInt64, UInt64, UInt64, UInt64)
    private var bufferCount: Int

    // Total bytes ever fed into `update`. Mixed into the final digest.
    private var totalLength: UInt64

    init(seed: UInt64 = 0) {
        self.seed = seed
        self.v1 = seed &+ XxHash64.prime1 &+ XxHash64.prime2
        self.v2 = seed &+ XxHash64.prime2
        self.v3 = seed &+ 0
        self.v4 = seed &- XxHash64.prime1
        self.buffer = (0, 0, 0, 0)
        self.bufferCount = 0
        self.totalLength = 0
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        let len = buf.count
        var p = base
        let end = base.advanced(by: len)
        totalLength &+= UInt64(len)

        // If we already have a partial stripe buffered, try to complete it.
        if bufferCount > 0 {
            let need = 32 - bufferCount
            if len < need {
                // Still not enough to finish a stripe. Append and return.
                copyIntoBuffer(src: p, count: len, offset: bufferCount)
                bufferCount += len
                return
            }
            copyIntoBuffer(src: p, count: need, offset: bufferCount)
            // Absorb the now-full stripe.
            withUnsafeBytes(of: &buffer) { raw in
                let lanes = raw.bindMemory(to: UInt64.self)
                v1 = XxHash64.round(v1, XxHash64.loadLE64(lanes[0]))
                v2 = XxHash64.round(v2, XxHash64.loadLE64(lanes[1]))
                v3 = XxHash64.round(v3, XxHash64.loadLE64(lanes[2]))
                v4 = XxHash64.round(v4, XxHash64.loadLE64(lanes[3]))
            }
            p = p.advanced(by: need)
            bufferCount = 0
        }

        // Consume as many full 32-byte stripes as possible directly from the
        // caller's buffer without copying.
        let stripeEnd = end.advanced(by: -32)
        while p <= stripeEnd {
            let lane0 = loadUInt64(p, offset: 0)
            let lane1 = loadUInt64(p, offset: 8)
            let lane2 = loadUInt64(p, offset: 16)
            let lane3 = loadUInt64(p, offset: 24)
            v1 = XxHash64.round(v1, lane0)
            v2 = XxHash64.round(v2, lane1)
            v3 = XxHash64.round(v3, lane2)
            v4 = XxHash64.round(v4, lane3)
            p = p.advanced(by: 32)
        }

        // Buffer the tail (<32 bytes) for next update or for finalize.
        let tail = end - p
        if tail > 0 {
            copyIntoBuffer(src: p, count: tail, offset: 0)
            bufferCount = tail
        }
    }

    mutating func finalize() -> UInt64 {
        var h64: UInt64
        if totalLength >= 32 {
            // Merge the four accumulators.
            h64 = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h64 = XxHash64.mergeRound(h64, v1)
            h64 = XxHash64.mergeRound(h64, v2)
            h64 = XxHash64.mergeRound(h64, v3)
            h64 = XxHash64.mergeRound(h64, v4)
        } else {
            // Short-input fast path: skip the accumulator state entirely.
            h64 = seed &+ XxHash64.prime5
        }

        h64 &+= totalLength

        // Absorb the trailing <32 bytes from our internal buffer.
        var remaining = bufferCount
        withUnsafeBytes(of: &buffer) { raw in
            var idx = 0
            // 8-byte chunks
            while remaining >= 8 {
                let k1 = XxHash64.round(0, raw.load(fromByteOffset: idx, as: UInt64.self).littleEndian)
                h64 ^= k1
                h64 = rotl(h64, 27) &* XxHash64.prime1 &+ XxHash64.prime4
                idx += 8
                remaining -= 8
            }
            // 4-byte chunk
            if remaining >= 4 {
                let w = UInt64(raw.load(fromByteOffset: idx, as: UInt32.self).littleEndian)
                h64 ^= w &* XxHash64.prime1
                h64 = rotl(h64, 23) &* XxHash64.prime2 &+ XxHash64.prime3
                idx += 4
                remaining -= 4
            }
            // Remaining bytes
            while remaining > 0 {
                let b = UInt64(raw.load(fromByteOffset: idx, as: UInt8.self))
                h64 ^= b &* XxHash64.prime5
                h64 = rotl(h64, 11) &* XxHash64.prime1
                idx += 1
                remaining -= 1
            }
        }

        // Final avalanche.
        h64 ^= h64 >> 33
        h64 &*= XxHash64.prime2
        h64 ^= h64 >> 29
        h64 &*= XxHash64.prime3
        h64 ^= h64 >> 32
        return h64
    }

    // MARK: - Primitives

    @inline(__always)
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* prime2)
        a = rotl(a, 31)
        return a &* prime1
    }

    @inline(__always)
    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let r = round(0, val)
        return ((acc ^ r) &* prime1) &+ prime4
    }

    @inline(__always)
    private static func loadLE64(_ v: UInt64) -> UInt64 {
        // `buffer` is written byte-for-byte from raw input, so the stored
        // UInt64 already has the host byte order matching the on-disk order;
        // on Apple Silicon / x86_64 that's little-endian. `littleEndian`
        // makes this correct regardless of host endianness.
        return v.littleEndian
    }

    @inline(__always)
    private mutating func copyIntoBuffer(src: UnsafeRawPointer, count: Int, offset: Int) {
        withUnsafeMutableBytes(of: &buffer) { raw in
            let dst = raw.baseAddress!.advanced(by: offset)
            dst.copyMemory(from: src, byteCount: count)
        }
    }

    // Load an unaligned little-endian UInt64 from a raw pointer. Raw buffers
    // from FileHandle / Data are not guaranteed to be 8-byte aligned, so we go
    // through `loadUnaligned` and swap to host order.
    @inline(__always)
    private func loadUInt64(_ p: UnsafeRawPointer, offset: Int) -> UInt64 {
        let raw = p.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        return UInt64(littleEndian: raw)
    }
}

@inline(__always)
private func rotl(_ x: UInt64, _ r: Int) -> UInt64 {
    return (x << r) | (x >> (64 - r))
}

// MARK: - File streaming

/// Why a file could not be hashed, as distinct from an I/O error.
enum HashError: Error, Sendable {
    /// The path is not a regular file — a device, FIFO, socket or directory.
    case notARegularFile(URL)
}

extension XxHash64 {
    /// Stream-hash the contents of `url` in fixed-size chunks without loading
    /// the whole file into memory. Intended for multi-GB source files.
    ///
    /// **Only regular files are hashed, and the check happens before `open`.**
    /// Every path that reaches here is untrusted: manifest entries name the file
    /// and a manifest's `destinations[]` names the root it resolves under, so
    /// containment (`ManifestWriter.resolve`) proves only that the entry stayed
    /// inside its *recorded* root — and a recorded root can be anywhere. A
    /// planted manifest with `"destinations": ["<lib>", "/dev"]` and an entry
    /// `zero` therefore passed every existing check and had `heal` read
    /// `/dev/zero`: measured still running at 12 s and **1,896 MB RSS**, killed
    /// by hand. The same shape reaches `verify` through any non-regular file
    /// sitting at a recorded path. The check precedes `open(2)` because opening a
    /// FIFO for reading *blocks* until a writer appears — an `fstat` on the
    /// descriptor would never run. The descriptor is re-checked after the open
    /// anyway, so swapping the path between the two only costs a refusal.
    ///
    /// **Each chunk is released as it is consumed.** `read(upToCount:)` returns
    /// an autoreleased `Data`; with no pool inside the loop every chunk survived
    /// to the end of the hash. No attacker needed — verifying one 3 GiB file
    /// peaked at **1,876 MiB RSS**, so an ordinary nightly verify over large
    /// video or RAW could put the machine under memory pressure.
    static func hash(fileAt url: URL, bufferSize: Int = 1 << 20, bypassCache: Bool = false) throws -> UInt64 {
        precondition(bufferSize > 0, "bufferSize must be positive")

        var pathInfo = stat()
        guard stat(url.path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFREG else {
            throw HashError.notARegularFile(url)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var openInfo = stat()
        guard fstat(handle.fileDescriptor, &openInfo) == 0, (openInfo.st_mode & S_IFMT) == S_IFREG else {
            throw HashError.notARegularFile(url)
        }

        // F_NOCACHE makes reads on this descriptor bypass the unified buffer
        // cache and come from the device. Copy verification uses it so a
        // just-written file is re-read from storage rather than from the very
        // pages we wrote — otherwise a verify pass proves nothing about what
        // actually landed on disk. Best-effort: a failure here is non-fatal.
        if bypassCache {
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        }

        var hasher = XxHash64()
        while true {
            let more = try autoreleasepool { () -> Bool in
                let chunk = try handle.read(upToCount: bufferSize) ?? Data()
                if chunk.isEmpty { return false }
                chunk.withUnsafeBytes { hasher.update($0) }
                return true
            }
            if !more { break }
        }
        return hasher.finalize()
    }
}

// MARK: - Self-validation

#if DEBUG
/// Known-answer vectors for `HasherTests`, which is what actually runs them.
///
/// This table used to be checked by a `xxHash64SelfCheck()` that **nothing
/// called**, using `assert` — a no-op in Release and a crash rather than a test
/// failure in Debug. Meanwhile every other test in the suite uses the hasher as a
/// *self-consistent oracle* (hash the source, hash the destination, compare),
/// which passes identically if the algorithm is wrong. So nothing in this repo
/// pinned the digests to XXH64 at all: a subtly wrong implementation would have
/// verified every copy against its own mistake and reported success.
///
/// The vectors below were re-derived from `xxh64sum` (xxHash 0.8.x) and exercise:
///   - empty input (short-path skipping accumulators)
///   - <8, <16, <32 byte inputs (finalize tail loop)
///   - exactly 32 bytes (single stripe, boundary)
///   - larger-than-stripe inputs (accumulator merge path)
///   - seeded inputs (the `seed` mixing)
/// Streaming splits are covered exhaustively in the test, not here.
///
/// Kept `internal` (not `private`) so `HasherTests` is the single consumer and
/// the table has one definition site. Debug-only: Release ships neither.
///   - empty input (short-path skipping accumulators)
///   - <8, <16, <32 byte inputs (finalize tail loop)
///   - exactly 32 bytes (single stripe, boundary)
///   - larger-than-stripe inputs (accumulator merge path)
///   - seeded inputs (the `seed` mixing)
///   - streaming with awkward split offsets (buffer-carry across updates)
enum XxHash64Vectors {
    struct Vector {
        let input: [UInt8]
        let seed: UInt64
        let expected: UInt64
        let label: String
    }

    static let vectors: [Vector] = [
        Vector(input: [],
               seed: 0,
               expected: 0xef46db3751d8e999,
               label: "empty, seed=0"),
        Vector(input: Array("a".utf8),
               seed: 0,
               expected: 0xd24ec4f1a98c6e5b,
               label: "\"a\", seed=0"),
        Vector(input: Array("abc".utf8),
               seed: 0,
               expected: 0x44bc2cf5ad770999,
               label: "\"abc\", seed=0"),
        Vector(input: Array("abcd".utf8),
               seed: 0,
               expected: 0xde0327b0d25d92cc,
               label: "\"abcd\", seed=0 (4-byte tail)"),
        Vector(input: Array("abcdefgh".utf8),
               seed: 0,
               expected: 0x3ad351775b4634b7,
               label: "\"abcdefgh\", seed=0 (8-byte tail)"),
        Vector(input: Array("The quick brown fox jumps over the lazy dog".utf8),
               seed: 0,
               expected: 0x0b242d361fda71bc,
               label: "pangram (43B, crosses 32-byte stripe)"),
        Vector(input: Array("0123456789ABCDEF".utf8),
               seed: 0,
               expected: 0x50ee91a9dd7aeaa6,
               label: "16B (<32, hits 8-byte tail twice)"),
        Vector(input: Array("0123456789ABCDEF0123456789ABCDEF".utf8),
               seed: 0,
               expected: 0x51acef020cd423b1,
               label: "exactly 32B (one stripe, no tail)"),
        Vector(input: Array("abc".utf8),
               seed: 1,
               expected: 0xbea9ca8199328908,
               label: "\"abc\", seed=1"),
        Vector(input: [],
               seed: 1,
               expected: 0xd5afba1336a3be4b,
               label: "empty, seed=1"),
        Vector(input: Array("Nobody inspects the spammish repetition".utf8),
               seed: 0xCAFEBABE,
               expected: 0x0fee2b3ae28ccbf5,
               label: "39B, seed=0xCAFEBABE"),

        // Sizes either side of the 32-byte stripe boundary, and inputs long
        // enough to run the accumulator loop many times — the region a
        // single-stripe-only bug leaves untouched. All from `xxh64sum`.
        Vector(input: [UInt8](repeating: 0x41, count: 31),
               seed: 0,
               expected: 0x04d4645ec33f5384,
               label: "31×'A' (one byte short of a stripe)"),
        Vector(input: [UInt8](repeating: 0x41, count: 33),
               seed: 0,
               expected: 0x01088411df50be7f,
               label: "33×'A' (one stripe + 1)"),
        Vector(input: [UInt8](repeating: 0x41, count: 64),
               seed: 0,
               expected: 0x09cfee27adb0debd,
               label: "64×'A' (two whole stripes, no tail)"),
        Vector(input: [UInt8](repeating: 0x78, count: 1000),
               seed: 0,
               expected: 0x4cb9a3b69cb700e1,
               label: "1000×'x' (31 stripes + 8-byte tail)"),
        Vector(input: (0..<512).map { UInt8($0 % 256) },
               seed: 0,
               expected: 0x7b3bfcaac0348ac0,
               label: "512B byte-ramp (every byte value twice; non-ASCII, exercises endianness)"),
    ]

}

#endif
