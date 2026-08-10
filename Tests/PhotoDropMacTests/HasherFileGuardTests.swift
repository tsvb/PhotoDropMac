import XCTest
import Darwin
@testable import PhotoDropMac

/// S-1 — `XxHash64.hash(fileAt:)` is the primitive under every verification claim
/// this app makes, and it used to open whatever path it was handed and read until
/// EOF.
///
/// **Threat model.** The paths reaching it are untrusted twice over: manifest
/// entries name the file, and a manifest's `destinations[]` names the root it is
/// resolved under. Containment (`ManifestWriter.resolve`) keeps an entry inside
/// its recorded root — but a *recorded root* can be anywhere, so a planted
/// manifest with `"destinations": ["<lib>", "/dev"]` and an entry `zero` passes
/// containment and makes `heal` hash `/dev/zero`. Measured before this guard:
/// still running at 12 s, **1,896 MB RSS**, needed SIGKILL. A FIFO is worse — the
/// `open()` itself blocks until a writer appears, so the guard has to `stat`
/// before it opens.
///
/// **Second, benign half.** No attacker required: verifying one 3 GiB file peaked
/// at **1,876 MiB RSS** because `read(upToCount:)` hands back an autoreleased
/// `Data` per chunk and the loop never drained a pool. A library of large video
/// or RAW could hit memory pressure during an ordinary nightly verify.
final class HasherFileGuardTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropHashGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - The primitive

    /// A character device reads as an endless (or empty) stream and is never a
    /// photo. `/dev/null` is the harmless member of the class — it returns EOF
    /// immediately, so before the guard this produced the digest of zero bytes
    /// and reported *success*, which is the same code path that runs away on
    /// `/dev/zero`.
    func testRefusesCharacterDevice() {
        XCTAssertThrowsError(try XxHash64.hash(fileAt: URL(fileURLWithPath: "/dev/null"))) { error in
            XCTAssertTrue(error is HashError, "expected a typed refusal, got \(error)")
        }
    }

    /// A directory: `open(2)` succeeds on one, so the refusal cannot wait for the
    /// first `read` to fail.
    func testRefusesDirectory() throws {
        let dir = try freshTempDir()
        XCTAssertThrowsError(try XxHash64.hash(fileAt: dir)) { error in
            XCTAssertTrue(error is HashError, "expected a typed refusal, got \(error)")
        }
    }

    /// **The check must happen before `open`.** Opening a FIFO for reading blocks
    /// until some process opens the write end, so a guard implemented as an
    /// `fstat` on the descriptor never runs at all — the hang moves from the read
    /// loop into the open. The watchdog is the assertion: this test *fails* on
    /// timeout, it does not skip.
    func testRefusesFIFOWithoutBlockingOnOpen() throws {
        let dir = try freshTempDir()
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "could not create the fixture FIFO")

        let done = DispatchSemaphore(value: 0)
        let threw = OSAllocatedUnfairLockBox(false)
        DispatchQueue.global().async {
            do { _ = try XxHash64.hash(fileAt: fifo) } catch { threw.value = true }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success,
                       "hashing a FIFO blocked — the regular-file check must precede open()")
        XCTAssertTrue(threw.value, "a FIFO must be refused, not hashed")
    }

    /// Regular files keep working, including the empty one.
    func testStillHashesRegularFiles() throws {
        let dir = try freshTempDir()
        let file = dir.appendingPathComponent("a.bin")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try XxHash64.hash(fileAt: file), 0x26C7827D889F6DA3)

        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(try XxHash64.hash(fileAt: empty), 0xEF46DB3751D8E999)
    }

    /// The benign half of S-1: streaming must be O(1) in memory, not O(file).
    ///
    /// Measured before the `autoreleasepool`: hashing a 3 GiB file peaked at
    /// 1,876 MiB RSS — every chunk's autoreleased `Data` survived to the end of
    /// the loop. 128 MiB here keeps the test cheap; the pre-fix growth would be
    /// ~128 MiB, so the 32 MiB bound separates the two by 4×.
    func testStreamingDoesNotAccumulateChunksInMemory() throws {
        let dir = try freshTempDir()
        let file = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 << 20)   // sparse: reads as zeros, costs no disk
        try handle.close()

        let before = residentBytes()
        _ = try XxHash64.hash(fileAt: file)
        let after = residentBytes()
        guard let before, let after else {
            return XCTFail("could not read the resident set size")
        }
        let grew = Int64(after) - Int64(before)
        XCTAssertLessThan(grew, 32 << 20,
                          "RSS grew \(grew >> 20) MiB hashing a 128 MiB file — the read loop is retaining chunks")
    }

    private func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

    // MARK: - The call sites that inherit it

    /// `verify` walks manifest-named paths. A FIFO sitting at a recorded path —
    /// reachable by an attacker who can write into the library, and by accident on
    /// any tree that isn't purely photos — used to wedge the whole run at that
    /// entry. It must be reported as unreadable and the run must finish.
    func testVerifyReportsANonRegularFileAsUnreadableRatherThanHanging() throws {
        let lib = try freshTempDir()
        let day = lib.appendingPathComponent("2026/2026-05-28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let real = day.appendingPathComponent("IMG_0001.CR2")
        try Data("photo".utf8).write(to: real)
        let realHash = try XxHash64.hash(fileAt: real)

        let fifo = day.appendingPathComponent("IMG_0002.CR2")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        try writeManifest(in: lib, destinations: [lib], entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/2026-05-28/IMG_0001.CR2",
                          bytes: 5, xxhash64: String(format: "%016llx", realHash), status: "verified"),
            ManifestEntry(name: "IMG_0002.CR2", path: "2026/2026-05-28/IMG_0002.CR2",
                          bytes: 5, xxhash64: String(format: "%016llx", realHash), status: "verified"),
        ])

        let outcome = runWithWatchdog(seconds: 10) { VerifyEngine.run(target: lib) }
        guard let report = outcome ?? nil else { return XCTFail("verify hung on a FIFO entry") }
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.issues.map(\.kind), [.unreadable])
        XCTAssertFalse(report.allGood)
    }

    /// The `--xattr` walk enumerates the tree itself, so its regular-file filter is
    /// the guard there; this pins it. A FIFO must be skipped outright — neither
    /// hashed nor counted as unstamped, since it is not library content.
    func testXattrWalkSkipsNonRegularFiles() throws {
        let lib = try freshTempDir()
        let file = lib.appendingPathComponent("IMG_0001.CR2")
        try Data("photo".utf8).write(to: file)
        XCTAssertTrue(FileChecksumXattr.stamp(try XxHash64.hash(fileAt: file), on: file))
        XCTAssertEqual(mkfifo(lib.appendingPathComponent("pipe").path, 0o600), 0)

        let outcome = runWithWatchdog(seconds: 10) { VerifyEngine.runXattr(folder: lib) }
        guard case .report(let report)? = outcome else {
            return XCTFail("the xattr walk hung or refused the folder")
        }
        XCTAssertEqual(report.verified, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }

    // MARK: - Helpers

    /// Runs `body` on a background queue and fails the test if it does not return
    /// in time. A timeout **fails** here; a hang is the defect under test, and a
    /// skip would print `** TEST SUCCEEDED **` over it.
    private func runWithWatchdog<T>(seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = body()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("timed out after \(seconds)s")
            return nil
        }
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private func writeManifest(in root: URL, destinations: [URL], entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000), source: nil,
            primaryDestination: root.path(percentEncoded: false),
            archiveDestination: nil,
            destinations: destinations.map { $0.path(percentEncoded: false) },
            verified: true, partial: false,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("ingest-test.json"))
    }
}

/// Tiny lock box so the watchdog closures can be `@Sendable`.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ initial: Bool) { storage = initial }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
