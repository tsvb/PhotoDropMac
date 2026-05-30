import XCTest
@testable import PhotoDropMac

/// Unit tests for the bounded LRU map backing the thumbnail cache — it must
/// retain values, cap its size, and evict the least-recently-used entry first.
final class LRUCacheTests: XCTestCase {
    func testStoresAndRetrievesValues() {
        var cache = LRUCache<Int, String>(capacity: 3)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        XCTAssertEqual(cache.value(for: 1), "a")
        XCTAssertEqual(cache.value(for: 2), "b")
        XCTAssertNil(cache.value(for: 99))
        XCTAssertEqual(cache.count, 2)
    }

    func testEvictsLeastRecentlyUsedBeyondCapacity() {
        var cache = LRUCache<Int, String>(capacity: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        cache.insert("c", for: 3)   // exceeds capacity → evict LRU (key 1)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: 1), "the least-recently-used entry is evicted")
        XCTAssertEqual(cache.value(for: 2), "b")
        XCTAssertEqual(cache.value(for: 3), "c")
    }

    func testAccessRefreshesRecency() {
        var cache = LRUCache<Int, String>(capacity: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        _ = cache.value(for: 1)     // touch 1 → now 2 is least-recent
        cache.insert("c", for: 3)   // evicts 2, keeps the recently-used 1
        XCTAssertEqual(cache.value(for: 1), "a")
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 3), "c")
    }

    func testReinsertUpdatesValueWithoutGrowing() {
        var cache = LRUCache<Int, String>(capacity: 2)
        cache.insert("a", for: 1)
        cache.insert("A", for: 1)   // same key, new value
        XCTAssertEqual(cache.value(for: 1), "A")
        XCTAssertEqual(cache.count, 1)
    }

    func testCapacityIsAtLeastOne() {
        var cache = LRUCache<Int, String>(capacity: 0)   // clamped to 1
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: 2), "b")
    }
}
