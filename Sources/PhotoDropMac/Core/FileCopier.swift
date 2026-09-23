import Foundation
import Darwin
import os

/// A thread-safe, one-way "cancelled" flag the copy loop polls cheaply from its
/// detached worker. The per-file copy runs in a `Task.detached`, which does
/// **not** inherit cancellation from the Copier's task — so `Task.checkCancellation()`
/// alone never fires for a user cancel mid-file. The Copier sets this flag from
/// its own task on cancel and threads it into `copyAndHash`, carrying the signal
/// across the detached boundary that `Task` cancellation can't cross.
final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func cancel() { state.withLock { $0 = true } }
    var isCancelled: Bool { state.withLock { $0 } }
}

enum FileCopierError: Error, CustomStringConvertible {
    case verificationMismatch(file: URL, expected: UInt64, actual: UInt64)
    case read(URL, any Error)
    case write(URL, any Error)
    case open(URL, any Error)
    case destinationExists(URL)
    /// A folder *below* the destination root is a symbolic link, so the copy
    /// would have landed outside the library. Carries the link itself.
    case destinationThroughSymlink(URL)

    /// The file this error is about. `read` and `open` can name either side of a
    /// copy, which is why callers deciding "did the *source* go away?" have to
    /// compare this against the source root rather than switch on the case.
    var url: URL {
        switch self {
        case let .verificationMismatch(file, _, _): return file
        case let .read(url, _):                     return url
        case let .write(url, _):                    return url
        case let .open(url, _):                     return url
        case let .destinationExists(url):           return url
        case let .destinationThroughSymlink(url):   return url
        }
    }

    var description: String {
        switch self {
        case .verificationMismatch(let f, let e, let a):
            return "Verification mismatch on \(f.lastPathComponent): expected \(String(format: "%016llx", e)), got \(String(format: "%016llx", a))"
        case .read(let f, let err):  return "Read failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .write(let f, let err): return "Write failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .open(let f, let err):  return "Open failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .destinationExists(let f):
            return "Refused to overwrite existing file \(f.lastPathComponent) — a destination-name collision the planner did not catch (e.g. a case-insensitive or Unicode-normalization match). Source left untouched."
        case .destinationThroughSymlink(let link):
            return "Refused to write through \(link.path(percentEncoded: false)) — it is a symbolic link inside the destination, so the copy would have landed outside it. Source left untouched."
        }
    }
}

enum FileCopier {
    // Streams `source` → `destination` in 1 MiB chunks, tee-hashing with
    // xxhash64 on the way. Creates the destination directory if missing.
    // Calls `onProgress` with the byte count of each chunk — sync, on the
    // calling thread; the caller decides how to reflect it (e.g. Task hop
    // to MainActor).
    //
    // Returns the xxhash64 digest of the stream. Throws `CancellationError` if
    // `isCancelled()` returns true between chunks (or the surrounding Task is
    // cancelled). An explicit signal is needed because the only caller runs this
    // in a Task.detached, which doesn't inherit Task cancellation — see
    // `CancellationFlag`.
    //
    // `destinationRoot` is the library the file belongs to. No symbolic link
    // *below* it is followed — see `openDirectory(_:under:)`. Nil treats the
    // destination's own folder as the root, which protects only the file itself.
    static func copyAndHash(
        source: URL,
        destination: URL,
        destinationRoot: URL? = nil,
        bufferSize: Int = 1 << 20,
        isCancelled: () -> Bool = { false },
        onProgress: (Int64) -> Void
    ) throws -> UInt64 {
        let destDir = destination.deletingLastPathComponent()
        let dirFD = try openDirectory(destDir, under: destinationRoot ?? destDir)
        defer { close(dirFD) }
        let name = destination.lastPathComponent

        // Only a regular file is read, and the open cannot block — see
        // `RegularFile`. `sync` hands this manifest-named paths from a library the
        // user may not have made: a FIFO there hung `open()` forever, and a
        // device streamed into the mirror until it filled.
        let inHandle: FileHandle
        do {
            inHandle = try FileHandle(fileDescriptor: RegularFile.openForReading(source),
                                      closeOnDealloc: false)
        } catch {
            throw FileCopierError.open(source, error)
        }
        defer { try? inHandle.close() }

        // Exclusive create. O_EXCL makes the kernel refuse to open a file that
        // already exists, so a destination-name collision the planner missed —
        // a case-insensitive or Unicode-normalization variant on APFS/HFS+, or
        // a TOCTOU race after the collision scan — can never silently truncate
        // and overwrite an existing photo. A refused overwrite surfaces as
        // `.destinationExists`, which the copy engine treats as a per-bundle
        // failure (rollback + continue), never as data loss. This is the only
        // thing standing between "nothing is ever overwritten" and a collision-
        // detection miss, so it lives at the syscall, not in a prior string check.
        //
        // Created relative to the folder descriptor opened above, so the path is
        // not re-walked (and cannot be redirected) between the check and the
        // create; O_NOFOLLOW states outright what O_EXCL already implies for a
        // link sitting at the final name.
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0 {
            let code = errno
            if code == EEXIST { throw FileCopierError.destinationExists(destination) }
            throw FileCopierError.open(destination, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
        let outHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        // From here on the file is ours — we just created it. Remove our own
        // partial write on any failure, so a thrown/cancelled copy never leaves
        // an orphan and the caller's bundle rollback never has to (and never
        // could) delete a pre-existing file we didn't write.
        do {
            defer { try? outHandle.close() }

            var hasher = XxHash64()

            while true {
                // Detached work doesn't inherit Task cancellation, so honour the
                // explicit flag too; either signal aborts here and the catch
                // below removes the partial file we created.
                if Task.isCancelled || isCancelled() { throw CancellationError() }

                let chunk: Data?
                do {
                    chunk = try inHandle.read(upToCount: bufferSize)
                } catch {
                    throw FileCopierError.read(source, error)
                }
                guard let data = chunk, !data.isEmpty else { break }

                do {
                    try outHandle.write(contentsOf: data)
                } catch {
                    throw FileCopierError.write(destination, error)
                }

                data.withUnsafeBytes { rawBuf in
                    hasher.update(rawBuf)
                }

                onProgress(Int64(data.count))
            }

            // Flush this file's data out of the page cache before we return.
            // Required on two counts: the cache-bypassing verify (F_NOCACHE) has to
            // be able to read the bytes back from the device, and a crash mustn't
            // lose a file we reported as copied. The stronger drive-cache barrier
            // (F_FULLFSYNC) is issued once per volume at end of job — see
            // fullSyncVolume — instead of per file, which would force a full device
            // flush for every tiny sidecar.
            try flushToDisk(outHandle, destination: destination)

            // Carry the source's timestamps across, `cp -p` style.
            //
            // Nothing set these, so every file in the library wore the *ingest*
            // time as both its modification and creation date. That is wrong on
            // its own terms — Finder's "Date Created" column and every downstream
            // tool keyed on file dates described the offload, not the shoot — and
            // it quietly destroyed evidence this app depends on: `ExifReader`
            // falls back to mtime whenever a file has no parseable capture date
            // (a sidecar, an unknown RAW), so ingesting an already-ingested
            // folder filed everything under the copy date with no way back.
            //
            // Best-effort by design: a destination that cannot carry timestamps
            // (some SMB shares) must not fail a copy whose bytes are correct and
            // verified. Timestamps are metadata; the photo is the payload.
            preserveTimestamps(from: source, toDescriptor: outHandle.fileDescriptor)

            return hasher.finalize()
        } catch {
            // We created this file; don't leave a partial behind on any failure.
            // Unlinked through the folder descriptor it was created in, for the
            // same reason it was created through it.
            _ = unlinkat(dirFD, name, 0)
            throw error
        }
    }

    /// Opens `directory` for use as an `openat` base, creating whatever is
    /// missing, **without following a symbolic link anywhere below `root`**.
    ///
    /// `createDirectory(withIntermediateDirectories:)` and `open()` both follow
    /// links in every component but the last, and `O_EXCL` guards only the last.
    /// So a destination library carrying its own link — a shared or downloaded
    /// one, `2026 -> /Users/Shared/x` or `-> ../..` — sent the user's photos and
    /// sidecars outside the library, while the manifest recorded them as
    /// `2026/…` and `verify` followed the same link and called them fine. A card
    /// author who could also plant the link chose the bytes written into any
    /// folder the user can write to. `DestinationTopology` checks the roots only.
    ///
    /// Each component below the root is made with `mkdirat` and entered with
    /// `openat(O_NOFOLLOW | O_DIRECTORY)`, one level at a time from the root's
    /// own descriptor, so there is no window between checking a component and
    /// using it. The root itself is the user's choice and may be reached through
    /// a link (`/tmp`, an alias); it is created if missing, exactly as before.
    /// This matches the rule `VerifyEngine.build` applies on the read side
    /// (`ManifestWriter.reachesThroughSymlink`), so nothing is written where a
    /// later `verify` would refuse to look.
    private static func openDirectory(_ directory: URL, under root: URL) throws -> Int32 {
        guard let below = ManifestWriter.componentsBelow(root, of: directory) else {
            throw FileCopierError.open(directory, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw FileCopierError.open(root, NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        var reached = root
        for component in below {
            reached = reached.appendingPathComponent(component, isDirectory: true)
            if mkdirat(fd, component, 0o777) != 0, errno != EEXIST {
                let code = errno
                close(fd)
                throw FileCopierError.write(reached, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                var info = stat()
                let isLink = fstatat(fd, component, &info, AT_SYMLINK_NOFOLLOW) == 0
                    && (info.st_mode & S_IFMT) == S_IFLNK
                close(fd)
                if isLink { throw FileCopierError.destinationThroughSymlink(reached) }
                throw FileCopierError.open(reached, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
            close(fd)
            fd = next
        }
        return fd
    }

    /// Copy the source's access/modification times, and its birth time where the
    /// destination filesystem keeps one, onto the just-written descriptor.
    ///
    /// Times are taken with nanosecond precision from the source's `stat`, so a
    /// destination on APFS keeps the full resolution the card recorded; exFAT
    /// truncates on its own and that is the filesystem's business, not ours.
    /// Birth time goes through `fsetattrlist`, the only interface that can set
    /// it — and it is set *after* the mtime, because creating and writing the
    /// file necessarily stamped "now" on both.
    private static func preserveTimestamps(from source: URL, toDescriptor fd: Int32) {
        var info = stat()
        guard stat(source.path, &info) == 0 else { return }

        var times = [
            timespec(tv_sec: info.st_atimespec.tv_sec, tv_nsec: info.st_atimespec.tv_nsec),
            timespec(tv_sec: info.st_mtimespec.tv_sec, tv_nsec: info.st_mtimespec.tv_nsec),
        ]
        _ = futimens(fd, &times)

        // ATTR_CMN_CRTIME is accepted by APFS/HFS+ and rejected elsewhere; the
        // return value is deliberately ignored for the same reason futimens' is.
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var birth = timespec(tv_sec: info.st_birthtimespec.tv_sec,
                             tv_nsec: info.st_birthtimespec.tv_nsec)
        _ = fsetattrlist(fd, &attrs, &birth, MemoryLayout<timespec>.size, 0)
    }

    // fsync the file's data through to the filesystem. Throws a write error on
    // failure — a copy we can't flush is not a copy we can trust.
    private static func flushToDisk(_ handle: FileHandle, destination: URL) throws {
        if fsync(handle.fileDescriptor) == 0 { return }
        throw FileCopierError.write(destination, NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
    }

    /// Issue a single drive-cache barrier against the volume `directory` lives
    /// on. F_FULLFSYNC asks the drive to flush *all* its buffered data to
    /// permanent storage, so one call — after every file has already been
    /// fsync'd — makes the whole job durable against power loss, far cheaper
    /// than a per-file barrier. Best-effort: returns false if the volume
    /// doesn't support it (some network/external mounts), in which case the
    /// data is still fsync'd, just not guaranteed past the drive's own cache.
    @discardableResult
    static func fullSyncVolume(at directory: URL) -> Bool {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fcntl(fd, F_FULLFSYNC) == 0
    }

    // Re-hashes `file` and compares against `expected`. Throws
    // `FileCopierError.verificationMismatch` on disagreement. The read bypasses
    // the page cache so verification reflects what landed on the device, not
    // the bytes still buffered from the copy.
    static func verify(file: URL, expectedHash: UInt64) throws {
        let actual = try XxHash64.hash(fileAt: file, bypassCache: true)
        if actual != expectedHash {
            throw FileCopierError.verificationMismatch(file: file, expected: expectedHash, actual: actual)
        }
    }
}
