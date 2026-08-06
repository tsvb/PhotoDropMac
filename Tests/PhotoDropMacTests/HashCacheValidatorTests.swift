import XCTest
@testable import PhotoDropMac

/// The hash cache's reuse rule.
///
/// A false *miss* costs a re-read; a false *hit* silently drops a photo (the
/// bundle is skipped as a duplicate, and skipped entries carry no digest so no
/// later verify can see the gap). The source-side key is
/// `<volumeUUID>|<path>` where every component is card-controlled, so the
/// identity check is the only thing standing between a look-alike card and
/// silent data loss.
final class HashCacheValidatorTests: XCTestCase {
    private func identity(size: Int64 = 1024,
                          mtimeNanos: Int64 = 1_716_000_000_123_456_789,
                          birthNanos: Int64 = 1_716_000_000_000_000_000) -> FileIdentity {
        FileIdentity(size: size, mtimeNanos: mtimeNanos, birthNanos: birthNanos)
    }

    func testMatchesExactIdentity() {
        let id = identity()
        XCTAssertTrue(HashCacheEntry(hash: 42, identity: id).matches(id))
    }

    func testRejectsSubSecondMtimeDifference() {
        // The old validator allowed a full second of slop, so a card crafted to
        // land within it inherited another card's digest.
        let cached = HashCacheEntry(hash: 42, identity: identity(mtimeNanos: 1_716_000_000_123_456_789))
        XCTAssertFalse(cached.matches(identity(mtimeNanos: 1_716_000_000_123_456_790)))
        XCTAssertFalse(cached.matches(identity(mtimeNanos: 1_716_000_000_923_456_789)))
    }

    func testRejectsDifferingSizeOrBirthTime() {
        let cached = HashCacheEntry(hash: 42, identity: identity())
        XCTAssertFalse(cached.matches(identity(size: 1025)))
        XCTAssertFalse(cached.matches(identity(birthNanos: 1_716_000_000_000_000_001)))
    }

    func testLegacyEntriesFailClosed() throws {
        // Caches written before the nanosecond fields existed decode with nil and
        // must be recomputed rather than trusted.
        let legacy = """
        {"hash":42,"size":1024,"mtime":1716000000.123}
        """
        let entry = try JSONDecoder().decode(HashCacheEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.mtimeNanos)
        XCTAssertFalse(entry.matches(identity()), "an entry with no precise identity must never match")
    }

    func testRoundTripsThroughJSON() throws {
        let entry = HashCacheEntry(hash: 0xDEADBEEF, identity: identity())
        let decoded = try JSONDecoder().decode(HashCacheEntry.self,
                                               from: try JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertTrue(decoded.matches(identity()))
    }
}
