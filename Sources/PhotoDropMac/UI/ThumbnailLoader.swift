import Foundation
import SwiftUI
import ImageIO

/// A tiny capacity-bounded LRU map. Not thread-safe on its own — callers provide
/// isolation (`ThumbnailLoader` is an actor). Evicts the least-recently-used
/// entry once `capacity` is exceeded.
struct LRUCache<Key: Hashable, Value> {
    private var store: [Key: Value] = [:]
    private var order: [Key] = []   // least-recent first, most-recent last
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { store.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        store[key] = value
        touch(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            store[oldest] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// Loads and caches downscaled thumbnails for the contact sheet. ImageIO pulls
/// an embedded preview when the file has one (fast for JPEG and most RAW). The
/// actor coordinates a bounded in-memory cache and de-dupes in-flight requests
/// for the same URL; the decode itself runs detached so several thumbnails
/// decode concurrently. SwiftUI's lazy grid only asks for visible cells, which
/// keeps the number of concurrent decodes bounded without an explicit semaphore.
actor ThumbnailLoader {
    private var cache: LRUCache<URL, Image>
    private var inFlight: [URL: Task<Image?, Never>] = [:]
    private let maxPixel: CGFloat

    /// `cacheLimit` bounds resident thumbnails so a large card can't grow memory
    /// without limit while scrolling — old thumbnails are re-decoded if revisited.
    init(maxPixel: CGFloat = 320, cacheLimit: Int = 512) {
        self.maxPixel = maxPixel
        self.cache = LRUCache(capacity: cacheLimit)
    }

    func image(for url: URL) async -> Image? {
        if let cached = cache.value(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let maxPixel = self.maxPixel
        let task = Task.detached(priority: .utility) {
            ThumbnailLoader.decode(url: url, maxPixel: maxPixel)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { cache.insert(result, for: url) }
        return result
    }

    nonisolated static func decode(url: URL, maxPixel: CGFloat) -> Image? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
