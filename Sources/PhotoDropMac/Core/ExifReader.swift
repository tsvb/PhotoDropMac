import Foundation
import ImageIO
import AVFoundation
import CoreMedia

enum ExifReader {
    static func dateTaken(for url: URL) -> Date? {
        if let exifDate = exifDateTaken(for: url) { return exifDate }
        // ImageIO cannot open a movie, so every clip fell straight through to the
        // file's mtime — which, for a card that has passed through any other
        // machine, is the *copy* time. Video is a first-class primary now, so it
        // gets a real capture date from the container's own metadata before the
        // mtime fallback is reached.
        return movieDateTaken(for: url)
    }

    private static func exifDateTaken(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }

        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)

        guard let dateString else { return nil }
        return parse(dateString)
    }

    /// Capture date for a movie container.
    ///
    /// Reads the asset's `creationDate` metadata — the QuickTime/MP4
    /// `com.apple.quicktime.creationdate` or the ISO `©day` atom, whichever the
    /// camera wrote. Unlike an EXIF string these carry a real timezone offset, so
    /// no local-zone reconstruction is needed or wanted.
    ///
    /// Synchronous on purpose: `dateTaken` is called from the detached scan for
    /// every primary, and the callers are already off the main actor. The
    /// deprecated synchronous accessors are used deliberately rather than
    /// restructuring the whole scan around `load(_:)` for a metadata read that
    /// touches only the container header.
    private static func movieDateTaken(for url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata where item.commonKey == .commonKeyCreationDate {
            if let date = item.dateValue { return date }
            // Some cameras write the creation date as a string rather than a
            // date value; QuickTime's is ISO-8601 with an offset.
            if let text = item.stringValue, let parsed = parseISO8601(text) { return parsed }
        }
        return nil
    }

    /// ISO-8601 with and without fractional seconds. Cameras differ, and a
    /// formatter configured for one returns nil for the other.
    private static func parseISO8601(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    // EXIF dates ("yyyy:MM:dd HH:mm:ss") carry no timezone. We parse in the
    // current zone so downstream day/year formatting matches the photographer's
    // intuitive local date.
    //
    // Parsed through `Calendar` rather than `DateFormatter`, because a
    // `DateFormatter` answers **nil** for a local time that does not exist — the
    // hour skipped by a DST spring-forward. Camera clocks do not observe DST, so
    // a camera left on standard time stamps exactly that hour for a full hour of
    // shooting: measured, `2026:03:08 02:30:00` in America/Los_Angeles returned
    // nil. Every frame from that hour then fell through to the file's mtime,
    // which — if the card has ever been copied through another machine — is the
    // *copy* time, filing an hour of a shoot under an unrelated date with no
    // indication anything happened. `Calendar.date(from:)` resolves the gap to
    // the instant the clocks jumped to, which is the closest real time to what
    // the camera meant.
    //
    // The component range checks are kept verbatim: `Calendar` is lenient by
    // default and would happily roll `2026:02:30` into March, and cameras really
    // do emit `0000:00:00 00:00:00` for an unset clock.
    /// `timeZone` is a parameter purely so the DST-gap behaviour is testable
    /// without mutating the process's default zone (which `TimeZone.current`
    /// caches, so a test that sets it gets the machine's real zone anyway).
    /// Production always uses the default.
    static func parse(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let date = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, time.count == 3 else { return nil }
        guard let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]) else { return nil }
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        guard let parsed = calendar.date(from: components) else { return nil }

        // Reject a date the calendar had to roll over (Feb 30 → Mar 2). A DST gap
        // is *not* a rollover — the day, month and year all survive it — so this
        // keeps the strictness the DateFormatter gave us without reintroducing
        // the nil that started this.
        let back = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return parsed
    }
}
