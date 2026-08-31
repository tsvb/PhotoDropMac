import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
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
/// decode concurrently.
///
/// **Failures are cached too.** A file ImageIO cannot decode returned nil and
/// nothing was recorded, so `ContactSheet` spun a `ProgressView` forever and
/// re-attempted the decode every time the cell scrolled back into view — the
/// most expensive possible response to a file that will never decode. The cache
/// therefore stores an `Outcome`, and the grid can say "no preview" instead of
/// pretending to still be working.
///
/// Concurrency is bounded by what SwiftUI's lazy grid asks for plus the
/// in-flight de-dup below. (This comment used to claim an explicit bound; there
/// was no semaphore then and there is none now. Better to describe what actually
/// limits it.)
actor ThumbnailLoader {
    /// A decode that finished, one way or the other.
    enum Outcome: Sendable, Equatable {
        case image(Image)
        /// ImageIO could not produce a preview. Terminal — do not retry.
        case undecodable
    }

    private var cache: LRUCache<URL, Outcome>
    private var inFlight: [URL: Task<Outcome, Never>] = [:]
    private let maxPixel: CGFloat

    /// `cacheLimit` bounds resident thumbnails so a large card can't grow memory
    /// without limit while scrolling — old thumbnails are re-decoded if revisited.
    init(maxPixel: CGFloat = 320, cacheLimit: Int = 512) {
        self.maxPixel = maxPixel
        self.cache = LRUCache(capacity: cacheLimit)
    }

    func image(for url: URL) async -> Image? {
        if case .image(let image) = await outcome(for: url) { return image }
        return nil
    }

    func outcome(for url: URL) async -> Outcome {
        if let cached = cache.value(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let maxPixel = self.maxPixel
        let task = Task.detached(priority: .utility) {
            ThumbnailLoader.decode(url: url, maxPixel: maxPixel).map(Outcome.image) ?? .undecodable
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        cache.insert(result, for: url)
        return result
    }

    nonisolated static func decode(url: URL, maxPixel: CGFloat) -> Image? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return Image(decorative: cgImage, scale: 1, orientation: .up)
        }
        // ImageIO can't open a movie container, so a clip decoded as
        // `.undecodable` and showed the contact sheet's placeholder — which is
        // also what a corrupt file looks like. Now that video is ingestable it
        // has to be cullable, which means it has to be visible.
        return decodeMovieFrame(url: url, maxPixel: maxPixel)
    }

    /// A poster frame for a movie.
    ///
    /// Taken a little way in rather than at zero: many cameras start a clip on a
    /// black or half-exposed frame, which is useless for culling.
    /// `requestedTimeToleranceBefore/After` are left at their defaults so the
    /// generator may snap to the nearest sync frame — exact seeking would decode
    /// far more of the file for no benefit at thumbnail size.
    nonisolated private static func decodeMovieFrame(url: URL, maxPixel: CGFloat) -> Image? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // honour rotation metadata
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let at = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: at, actualTime: nil)
            ?? generator.copyCGImage(at: .zero, actualTime: nil)
        else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
