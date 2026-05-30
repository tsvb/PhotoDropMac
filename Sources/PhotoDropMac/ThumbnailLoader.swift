import Foundation
import SwiftUI
import ImageIO

/// Loads and caches downscaled thumbnails for the contact sheet. ImageIO pulls
/// an embedded preview when the file has one (fast for JPEG and most RAW). The
/// actor coordinates an in-memory cache and de-dupes in-flight requests for the
/// same URL; the decode itself runs detached so several thumbnails decode
/// concurrently. SwiftUI's lazy grid only asks for visible cells, which keeps
/// the number of concurrent decodes bounded without an explicit semaphore.
actor ThumbnailLoader {
    private var cache: [URL: Image] = [:]
    private var inFlight: [URL: Task<Image?, Never>] = [:]
    private let maxPixel: CGFloat

    init(maxPixel: CGFloat = 320) { self.maxPixel = maxPixel }

    func image(for url: URL) async -> Image? {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let maxPixel = self.maxPixel
        let task = Task.detached(priority: .utility) {
            ThumbnailLoader.decode(url: url, maxPixel: maxPixel)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { cache[url] = result }
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
