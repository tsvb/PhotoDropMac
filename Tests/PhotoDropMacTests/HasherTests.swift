import XCTest
@testable import PhotoDropMac

/// The hash is the product. Every verification claim this app makes — the copy
/// verify, the manifest, the xattr, `heal`'s "a healthy copy exists" — reduces to
/// "these two digests are equal", so an implementation that is wrong but
/// *self-consistent* would confirm every one of them and be invisible.
///
/// **Measured before-state.** Nothing pinned the digests to XXH64. The vector
/// table existed but was checked only by `xxHash64SelfCheck()`, which had **zero
/// callers** in `Sources/` or `Tests/` (and used `assert`, a no-op in Release).
/// Every other test used the hasher as its own oracle: hash the source, hash the
/// destination, compare. A transposed prime or a mishandled tail would have
/// passed all 243 of them.
///
/// Expected digests here come from `xxh64sum` (xxHash 0.8.x, Homebrew), an
/// independent C implementation, not from this code.
final class HasherTests: XCTestCase {

    private func digest(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        var h = XxHash64(seed: seed)
        bytes.withUnsafeBufferPointer { h.update(UnsafeRawBufferPointer($0)) }
        return h.finalize()
    }

    /// Known-answer test against the reference implementation.
    func testMatchesReferenceVectors() {
        XCTAssertFalse(XxHash64Vectors.vectors.isEmpty, "the table itself must not go missing")
        for v in XxHash64Vectors.vectors {
            XCTAssertEqual(digest(v.input, seed: v.seed), v.expected,
                           "\(v.label): expected 0x\(String(v.expected, radix: 16)), "
                         + "got 0x\(String(digest(v.input, seed: v.seed), radix: 16))")
        }
    }

    /// Tee-hashing feeds the digest in 1 MiB chunks, so a chunk boundary can land
    /// anywhere. Every possible split of a message that spans several stripes
    /// must give the same digest as hashing it whole — this is the property that
    /// makes `FileCopier.copyAndHash` equivalent to hashing the file afterwards.
    func testEverySplitOffsetAgreesWithTheWholeMessage() {
        let message = (0..<300).map { UInt8(($0 &* 31 &+ 7) % 256) }
        let whole = digest(message)

        for splitAt in 0...message.count {
            var streamed = XxHash64()
            Array(message.prefix(splitAt)).withUnsafeBufferPointer {
                streamed.update(UnsafeRawBufferPointer($0))
            }
            Array(message.dropFirst(splitAt)).withUnsafeBufferPointer {
                streamed.update(UnsafeRawBufferPointer($0))
            }
            XCTAssertEqual(streamed.finalize(), whole, "split at \(splitAt) disagreed")
        }
    }

    /// Many small updates — the buffer-carry path, where a partial stripe has to
    /// survive across calls.
    func testManySmallUpdatesAgreeWithOneLargeOne() {
        let message = (0..<1000).map { UInt8($0 % 251) }
        let whole = digest(message)

        for chunk in [1, 2, 3, 5, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128] {
            var streamed = XxHash64()
            var offset = 0
            while offset < message.count {
                let piece = Array(message[offset..<min(offset + chunk, message.count)])
                piece.withUnsafeBufferPointer { streamed.update(UnsafeRawBufferPointer($0)) }
                offset += chunk
            }
            XCTAssertEqual(streamed.finalize(), whole, "chunk size \(chunk) disagreed")
        }
    }

    /// A zero-length update mid-stream must be a no-op, not a state change.
    /// `FileCopier` can emit one at EOF.
    func testEmptyUpdateIsANoOp() {
        let message = Array("The quick brown fox jumps over the lazy dog".utf8)
        var streamed = XxHash64()
        [].withUnsafeBufferPointer { (b: UnsafeBufferPointer<UInt8>) in
            streamed.update(UnsafeRawBufferPointer(b))
        }
        Array(message.prefix(10)).withUnsafeBufferPointer { streamed.update(UnsafeRawBufferPointer($0)) }
        [].withUnsafeBufferPointer { (b: UnsafeBufferPointer<UInt8>) in
            streamed.update(UnsafeRawBufferPointer(b))
        }
        Array(message.dropFirst(10)).withUnsafeBufferPointer { streamed.update(UnsafeRawBufferPointer($0)) }
        XCTAssertEqual(streamed.finalize(), 0x0b242d361fda71bc)
    }

    /// A one-bit change anywhere must change the digest. Cheap, but it is the
    /// property the whole product rests on, and a truncating or
    /// last-stripe-ignoring bug fails it at a specific offset rather than
    /// everywhere.
    func testASingleFlippedBitChangesTheDigestAtEveryOffset() {
        var base = [UInt8](repeating: 0xA5, count: 200)
        let original = digest(base)
        for i in base.indices {
            base[i] ^= 0x01
            XCTAssertNotEqual(digest(base), original, "flipping byte \(i) did not change the digest")
            base[i] ^= 0x01
        }
    }

    /// `hash(fileAt:)` — the entry point four of the five call sites use — must
    /// agree with the in-memory digest, including across the 1 MiB read boundary.
    func testFileHashingAgreesWithInMemoryHashing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HasherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        // Either side of the 1 MiB chunk size, and empty.
        for size in [0, 1, 4096, 1024 * 1024 - 1, 1024 * 1024, 1024 * 1024 + 1] {
            let bytes = (0..<size).map { UInt8(($0 &* 7 &+ 3) % 256) }
            let url = tmp.appendingPathComponent("f\(size).bin")
            try Data(bytes).write(to: url)
            XCTAssertEqual(try XxHash64.hash(fileAt: url, bypassCache: true), digest(bytes),
                           "file of \(size) bytes disagreed with the in-memory digest")
        }
    }
}
