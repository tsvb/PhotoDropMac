import Foundation
import Darwin

/// Opening a path the app did not create, for reading, without letting it name
/// something that is not a file.
///
/// `XxHash64.hash(fileAt:)` learned this rule first (see `HashError`); two other
/// readers of untrusted paths never did:
///
/// - **`FileCopier.copyAndHash`** read its source with
///   `FileHandle(forReadingFrom:)`. `sync` feeds it manifest-named files from a
///   library the user may not have made, so a library entry that is a FIFO
///   blocked `open()` forever, and one that is a character device streamed into
///   the mirror until the disk filled — the digest is only compared at EOF.
/// - **Manifest loading** used `Data(contentsOf:)` on every `*.json` in
///   `PhotoDrop Manifests/`, filtered by extension alone. A FIFO named `x.json`
///   hung `verify`, `heal` and `sync` — including the nightly agent — and a
///   symlink to `/dev/zero` grew memory without bound.
///
/// **The type check is made on the open descriptor, and the open cannot block.**
/// `open()` on a FIFO waits for a writer, so a plain open-then-`fstat` never
/// reaches the check; `O_NONBLOCK` makes that open return at once, the `fstat`
/// then refuses anything that is not `S_IFREG`, and the flag is cleared before
/// the caller reads. Checking the descriptor rather than the path also closes the
/// gap a `stat`-then-`open` leaves for the path to be swapped in between.
/// Symlinks are still followed — their *target* must be a regular file — which is
/// what a user's own aliased folder needs; manifest-named paths that pass through
/// a link are refused earlier, by `VerifyEngine.build`.
enum RegularFile {
    /// Why a path was refused before any byte was read.
    enum RefusalError: Error, LocalizedError {
        case notARegularFile(URL)
        case tooLarge(URL, limit: Int)

        var errorDescription: String? {
            switch self {
            case .notARegularFile(let url):
                return "\(url.lastPathComponent) is not a regular file (a device, FIFO, socket or folder), so it was not read."
            case .tooLarge(let url, let limit):
                return "\(url.lastPathComponent) is larger than \(limit) bytes, so it was not read."
            }
        }
    }

    /// Opens `url` read-only and returns its descriptor, or throws if it cannot be
    /// opened or is not a regular file. The caller owns the descriptor.
    static func openForReading(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw RefusalError.notARegularFile(url)
        }
        // Back to ordinary blocking reads. For a regular file O_NONBLOCK changes
        // nothing, but a descriptor handed onward should carry no surprises.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return fd
    }

    /// The whole contents of `url`, if it is a regular file of at most `maxBytes`.
    /// Bounded by the read itself as well as by the size `fstat` reports, so a
    /// file that grows while it is read still cannot exceed the cap.
    static func contents(of url: URL, maxBytes: Int) throws -> Data {
        let fd = try openForReading(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= off_t(maxBytes) else {
            throw RefusalError.tooLarge(url, limit: maxBytes)
        }
        // Chunked rather than one `read(upToCount: maxBytes)`, which is free to
        // size its buffer from the count it is given.
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maxBytes else { throw RefusalError.tooLarge(url, limit: maxBytes) }
        }
        return data
    }
}
