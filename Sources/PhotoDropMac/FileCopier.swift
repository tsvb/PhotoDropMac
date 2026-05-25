import Foundation
import Darwin

enum FileCopierError: Error, CustomStringConvertible {
    case verificationMismatch(file: URL, expected: UInt64, actual: UInt64)
    case read(URL, any Error)
    case write(URL, any Error)
    case open(URL, any Error)

    var description: String {
        switch self {
        case .verificationMismatch(let f, let e, let a):
            return "Verification mismatch on \(f.lastPathComponent): expected \(String(format: "%016llx", e)), got \(String(format: "%016llx", a))"
        case .read(let f, let err):  return "Read failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .write(let f, let err): return "Write failed on \(f.lastPathComponent): \(err.localizedDescription)"
        case .open(let f, let err):  return "Open failed on \(f.lastPathComponent): \(err.localizedDescription)"
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

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outHandle: FileHandle
        do {
            outHandle = try FileHandle(forWritingTo: destination)
        } catch {
            throw FileCopierError.open(destination, error)
        }
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

        // Flush the written bytes all the way to stable storage before we
        // return. Closing the handle alone only reaches the OS page cache, so a
        // verify (or the user ejecting the card) could otherwise act on data
        // that isn't actually durable on the destination yet.
        try flushToDisk(outHandle, destination: destination)

        return hasher.finalize()
    }

    // Force a file's data to the storage device. F_FULLFSYNC is the only macOS
    // call that asks the drive to flush its own write cache — plain fsync can
    // return before the platter/flash is truly written. We fall back to fsync
    // on volumes that don't support F_FULLFSYNC (some network/external mounts
    // return ENOTSUP), and surface a write error only if both fail.
    private static func flushToDisk(_ handle: FileHandle, destination: URL) throws {
        let fd = handle.fileDescriptor
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        if fsync(fd) == 0 { return }
        throw FileCopierError.write(destination, NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
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
