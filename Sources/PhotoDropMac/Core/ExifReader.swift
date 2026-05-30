import Foundation
import ImageIO

enum ExifReader {
    static func dateTaken(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }

        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)

        guard let dateString else { return nil }
        return parse(dateString)
    }

    // EXIF dates ("yyyy:MM:dd HH:mm:ss") carry no timezone. We parse in the
    // current zone so downstream day/year formatting matches the photographer's
    // intuitive local date.
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}
