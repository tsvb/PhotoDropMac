import Foundation

/// Stores and reads a file's xxHash64 digest in an extended attribute, so a file
/// carries its own checksum and can be verified even after the library is
/// reorganized or its manifest is lost.
///
/// **Secondary and best-effort.** Extended attributes are stripped by exFAT/FAT
/// (memory cards), some cloud sync, zip/email, and `cp -X`, so the verification
/// manifest remains the authoritative record — this is a convenience layer that
/// travels *with* the file. A failed stamp is silently ignored; an absent
/// attribute means "unstamped", never "changed".
enum FileChecksumXattr {
    static let name = "com.tsvb.photodrop.xxh64"

    /// Write `hash` (as a 16-char hex string) to the file's xattr. Returns false
    /// if the attribute can't be set (e.g. the volume doesn't support xattrs).
    @discardableResult
    static func stamp(_ hash: UInt64, on url: URL) -> Bool {
        let bytes = Array(String(format: "%016llx", hash).utf8)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return bytes.withUnsafeBytes { raw in
                setxattr(path, name, raw.baseAddress, raw.count, 0, 0) == 0
            }
        }
    }

    /// Read the stored digest, or nil if the attribute is absent or unreadable.
    static func read(from url: URL) -> UInt64? {
        url.withUnsafeFileSystemRepresentation { path -> UInt64? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
            return UInt64(String(decoding: buffer, as: UTF8.self), radix: 16)
        }
    }
}
