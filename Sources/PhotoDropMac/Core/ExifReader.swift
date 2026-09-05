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

    /// Camera identity for a still, from the same properties dictionary the date
    /// comes from — one `CGImageSourceCopyPropertiesAtIndex` call, no extra I/O.
    ///
    /// The body serial is the field that actually separates two identical bodies
    /// covering one event; the model alone does not. Both are empty when the
    /// camera didn't write them, which is normal for phones and older bodies, and
    /// an empty named token drops its optional group.
    static func cameraInfo(for url: URL) -> (model: String, serial: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return ("", "") }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? ""
        let serial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String)
            ?? (props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])
                .flatMap { $0[kCGImagePropertyExifAuxSerialNumber] as? String }
            ?? ""
        return (model.trimmingCharacters(in: .whitespaces),
                serial.trimmingCharacters(in: .whitespaces))
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
    /// camera wrote. The **string** form is consulted first: it is the only one
    /// that still carries the camera's UTC offset, and `dateValue` is the same
    /// instant with that offset already thrown away. See `movieCaptureDate` for
    /// why the offset decides which day folder a clip lands in.
    ///
    /// Synchronous on purpose: `dateTaken` is called from the detached scan for
    /// every primary, and the callers are already off the main actor. The
    /// deprecated synchronous accessors are used deliberately rather than
    /// restructuring the whole scan around `load(_:)` for a metadata read that
    /// touches only the container header.
    private static func movieDateTaken(for url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata where item.commonKey == .commonKeyCreationDate {
            if let text = item.stringValue, let parsed = movieCaptureDate(from: text) { return parsed }
            if let date = item.dateValue { return date }
        }
        return nil
    }

    /// The capture date a movie timestamp stands for — on the same terms as a
    /// still's.
    ///
    /// An EXIF timestamp is a wall clock with no zone, and `parse` rebuilds it
    /// in the Mac's zone so a frame shot at 08:00 files under 08:00 — the
    /// photographer's own reading of the day — wherever the card is ingested. A
    /// QuickTime timestamp carries the camera's UTC offset instead
    /// (`2026-05-29T08:00:00+0900`), and this used to render that *instant* in
    /// the Mac's zone: 19:00 the previous day in New York. Measured: a still and
    /// a clip from the same Tokyo morning, ingested at home, filed under two
    /// different day folders. The stills rule is the one the app promises, so a
    /// clip's wall clock is taken **as the camera wrote it** and rebuilt in the
    /// Mac's zone exactly as an EXIF string is.
    ///
    /// Three shapes, three answers:
    /// - A numeric offset (`+09:00`, `-0400`, and `+00:00` too) is the camera
    ///   saying where it was: the wall clock in front of the designator is the
    ///   capture time, rebuilt locally.
    /// - `Z` is a camera that stores a true UTC instant and does not know where
    ///   it was (action cams and drones do this). There is no wall clock to
    ///   recover, so the instant is kept and renders in the Mac's zone — the
    ///   best available answer, and exactly what happened before.
    /// - No designator at all is a bare wall clock, the shape EXIF has, and gets
    ///   EXIF's treatment.
    ///
    /// `zone` is a parameter for the reason `parse`'s is: testability without
    /// mutating the process's default zone. Production uses `.current`.
    static func movieCaptureDate(from text: String, renderIn zone: TimeZone = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }

        var fields: [Int] = []
        for i in 1...6 {
            guard let range = Range(match.range(at: i), in: s), let value = Int(s[range]) else { return nil }
            fields.append(value)
        }
        let designator = Range(match.range(at: 7), in: s).map { String(s[$0]) } ?? ""

        // "Z": no wall clock to recover — the instant, exactly as written.
        // Anything else: the wall clock the camera wrote, rebuilt in `zone`.
        let wallClockZone: TimeZone = designator == "Z" ? .gmt : zone
        return localDate(year: fields[0], month: fields[1], day: fields[2],
                         hour: fields[3], minute: fields[4], second: fields[5], in: wallClockZone)
    }

    // EXIF dates ("yyyy:MM:dd HH:mm:ss") carry no timezone. We parse in the
    // current zone so downstream day/year formatting matches the photographer's
    // intuitive local date.
    //
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
        return localDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, in: timeZone)
    }

    /// A wall clock as a `Date` in `zone`, with the range checks and the
    /// DST-gap rule every capture time goes through — EXIF strings and movie
    /// timestamps alike, so the two cannot drift apart.
    ///
    /// Built through `Calendar` rather than `DateFormatter`, because a
    /// `DateFormatter` answers **nil** for a local time that does not exist —
    /// the hour skipped by a DST spring-forward. Camera clocks do not observe
    /// DST, so a camera left on standard time stamps exactly that hour for a
    /// full hour of shooting: measured, `2026:03:08 02:30:00` in
    /// America/Los_Angeles returned nil. Every frame from that hour then fell
    /// through to the file's mtime, which — if the card has ever been copied
    /// through another machine — is the *copy* time, filing an hour of a shoot
    /// under an unrelated date with no indication anything happened.
    /// `Calendar.date(from:)` resolves the gap to the instant the clocks jumped
    /// to, which is the closest real time to what the camera meant.
    ///
    /// The component range checks are kept verbatim: `Calendar` is lenient by
    /// default and would happily roll `2026:02:30` into March, and cameras really
    /// do emit `0000:00:00 00:00:00` for an unset clock.
    private static func localDate(year: Int, month: Int, day: Int,
                                  hour: Int, minute: Int, second: Int,
                                  in zone: TimeZone) -> Date? {
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
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
