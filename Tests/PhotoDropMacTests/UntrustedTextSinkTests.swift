import XCTest
@testable import PhotoDropMac

/// S-3 and S-5 — the two sinks that untrusted text reached without being
/// neutralized, and the class of character the existing filters were calibrated
/// too narrowly for.
///
/// **Threat model.** A filename is chosen by whoever wrote the card. It travels
/// verbatim into the manifest, the CSV, the on-disk job log, the CLI's terminal
/// output, and the `heal` restore script. Three of those are *rendered* to a
/// human — a terminal honours C0 escapes, a shell comment ends at a newline, and
/// any modern renderer reorders text around U+202E — so a filename can rewrite
/// what the reader sees. That is the whole attack: not privilege, but forging the
/// record a user checks after the fact.
///
/// **Measured before-state.** Confirmed against a real ingest log: a file named
/// `IMG\u{1B}[2K\u{1B}[1A0002.CR2` erased the preceding VERIFY line when the log
/// was `cat`ed, and a raw newline in a name forged an entire fabricated log
/// record complete with timestamp and kind. Separately, a filename containing
/// U+202E produced a **live** `mkdir -p … && cp -p …` line in the restore script
/// rather than a commented-out one, because `hasControlCharacters` stopped at
/// U+007F.
final class UntrustedTextSinkTests: XCTestCase {

    // MARK: - The shared primitive

    func testDisplayEscapesC0AndDEL() {
        XCTAssertEqual(SafeText.display("a\nb"), "a\\nb")
        XCTAssertEqual(SafeText.display("a\rb"), "a\\rb")
        XCTAssertEqual(SafeText.display("a\tb"), "a\\tb")
        XCTAssertEqual(SafeText.display("IMG\u{1B}[2K.CR2"), "IMG\\x1B[2K.CR2")
        XCTAssertEqual(SafeText.display("a\u{7F}b"), "a\\x7Fb")
    }

    /// The S-5 class: quoting and escaping are *correct* for these, and useless.
    /// They carry no control semantics — they change how the surrounding text is
    /// laid out, which defeats the human review the restore script's safety model
    /// rests on.
    func testDisplayEscapesBidiAndInvisibleFormatting() {
        for scalar: Unicode.Scalar in ["\u{202E}", "\u{200F}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{2028}"] {
            let escaped = SafeText.display("a\(scalar)b")
            XCTAssertFalse(escaped.unicodeScalars.contains(scalar),
                           "U+\(String(scalar.value, radix: 16, uppercase: true)) survived into displayed text")
            XCTAssertTrue(escaped.hasPrefix("a\\u{"), "expected a readable escape, got \(escaped)")
        }
    }

    /// Ordinary non-ASCII text is not mangled — a photographer's `Île_de_Ré.CR2`
    /// or `写真.ARW` has to stay legible, or the neutralizer becomes the thing
    /// that makes the log unreadable.
    func testDisplayLeavesOrdinaryTextAlone() {
        for s in ["IMG_0001.CR2", "Île_de_Ré.CR2", "写真.ARW", "a b — c"] {
            XCTAssertEqual(SafeText.display(s), s)
        }
    }

    func testDangerousControlPredicateCoversBothClasses() {
        XCTAssertTrue(SafeText.containsDangerousControls("a\u{1B}b"))
        XCTAssertTrue(SafeText.containsDangerousControls("a\nb"))
        XCTAssertTrue(SafeText.containsDangerousControls("a\u{7F}b"))
        XCTAssertTrue(SafeText.containsDangerousControls("a\u{202E}b"))
        XCTAssertTrue(SafeText.containsDangerousControls("a\u{2066}b"))
        XCTAssertFalse(SafeText.containsDangerousControls("IMG_0001.CR2"))
        XCTAssertFalse(SafeText.containsDangerousControls("Île_de_Ré.CR2"))
    }

    // MARK: - S-3: the job log

    /// The log is the artifact users read to reconstruct what happened to their
    /// photos. One entry must occupy exactly one line, and must not be able to
    /// drive the terminal it is `cat`ed into.
    func testJobLogNeutralizesCardFilenames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let hostile = "IMG\u{1B}[2K\u{1B}[1A0002.CR2"
        let forged = "a.CR2\n14:00:00.000  VERIFY    everything is fine"
        let url = try XCTUnwrap(JobLogger.write(
            entries: [
                LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), kind: .copied,
                         line: hostile, signature: nil),
                LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), kind: .copied,
                         line: forged, signature: nil),
            ],
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            elapsedSeconds: 1,
            primaryDestination: URL(fileURLWithPath: "/lib"),
            archiveDestinations: [],
            directory: dir))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.unicodeScalars.contains("\u{1B}"),
                       "an ESC from a card filename reached the log verbatim")
        XCTAssertTrue(text.contains("IMG\\x1B[2K\\x1B[1A0002.CR2"))
        // Two entries → two entry lines. The forged one must not become a third.
        let entryLines = text.split(separator: "\n").filter { $0.contains("COPY") }
        XCTAssertEqual(entryLines.count, 2, "a newline in a filename forged a log record")
        XCTAssertTrue(text.contains("a.CR2\\n14:00:00.000  VERIFY"))
    }

    // MARK: - S-5: the restore script

    /// The restore script's entire safety model is "a human reviews every
    /// executable line." A right-to-left override reorders that line in the
    /// reviewer's editor while the shell reads it unchanged, so it has to be
    /// treated exactly like a raw newline: no executable line, ever.
    func testRestoreScriptRefusesToEmitALiveLineForABidiPath() {
        let report = HealReport(
            healthy: 0,
            candidates: [HealCandidate(
                relPath: "2026/IMG\u{202E}gpj.CR2",
                kind: .missing,
                badPath: "/lib/2026/IMG\u{202E}gpj.CR2",
                recoverableFrom: "/nas/2026/IMG\u{202E}gpj.CR2")],
            manifestCount: 1)

        let script = HealEngine.restoreScript(report)
        XCTAssertFalse(script.contains("\ncp "), "a bidi path earned a live cp line")
        XCTAssertFalse(script.contains("mkdir -p '"), "a bidi path earned a live mkdir line")
        XCTAssertTrue(script.contains("# SKIPPED"))
        XCTAssertFalse(script.unicodeScalars.contains("\u{202E}"),
                       "the override survived even into the comment, where it reorders the review")
    }

    /// …and an ordinary path still gets its executable line. The guard is
    /// worthless if it swallows the feature.
    func testRestoreScriptStillEmitsOrdinaryLines() {
        let report = HealReport(
            healthy: 0,
            candidates: [HealCandidate(relPath: "2026/IMG_0001.CR2", kind: .missing,
                                       badPath: "/lib/2026/IMG_0001.CR2",
                                       recoverableFrom: "/nas/2026/IMG_0001.CR2")],
            manifestCount: 1)
        XCTAssertTrue(HealEngine.restoreScript(report).contains("mkdir -p '/lib/2026' && cp -p '/nas/2026/IMG_0001.CR2' '/lib/2026/IMG_0001.CR2'"))
    }
}
