import Foundation
import Darwin

enum FileCopierError: Error, CustomStringConvertible {
    case verificationMismatch(file: URL, expected: UInt64, actual: UInt64)
    case read(URL, any Error)
    case write(URL, any Error)
    case open(URL, any Error)
    case destinationExists(URL)

    var description: String {
        switch self {
        case .verificationMismatch(let f, let e, let a):
            return "Verification mismatch on \(f.lastPathComponent): expected \(String(format: "%016llx", e)), got \(String(format: "%016llx", a))"
        case .read(let f, let err):  return "Read failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .write(let f, let err): return "Write failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .open(let f, let err):  return "Open failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .destinationExists(let f):
            return "Refused to overwrite existing file \(f.lastPathComponent) — a destination-name collision the planner did not catch (e.g. a case-insensitive or Unicode-normalization match). Source left untouched."
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
    // Returns the xxhash64 digest of the stream. Throws `CancellationError`
    // if the surrounding Task is cancelled.
    static func copyAndHash(
        source: URL,
        destination: URL,
        bufferSize: Int = 1 << 20,
        onProgress: (Int64) -> Void
    ) throws -> UInt64 {
        let destDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let inHandle: FileHandle
        do {
            inHandle = try FileHandle(forReadingFrom: source)
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
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
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
                try Task.checkCancellation()

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

            return hasher.finalize()
        } catch {
            // We created this file; don't leave a partial behind on any failure.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
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
