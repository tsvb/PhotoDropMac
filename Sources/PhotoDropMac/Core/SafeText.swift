import Foundation

/// Neutralization of card- and manifest-derived text at the sinks where a human
/// reads it.
///
/// **Why this lives in Core.** The same rule was written twice — once in the
/// CLI's `CLIOutput.safe` and once in `HealEngine.comment` — and missed at a
/// third sink entirely (`JobLogger`, the log users actually read afterwards).
/// That is this codebase's characteristic failure: a correct mechanism applied
/// at some sinks and not others. One definition, one threat model, every sink.
///
/// **What is dangerous, and why the C0-only filter was too narrow.** Two classes:
///
/// - *Control characters* (C0, DEL, C1) carry semantics wherever the text is
///   rendered. A terminal honours `\u{1B}[2K`; a shell comment ends at `\n`.
///   Confirmed against a real ingest log: a file named
///   `IMG\u{1B}[2K\u{1B}[1A0002.CR2` erased the preceding VERIFY line when the
///   log was `cat`ed, and a raw newline forged a whole fabricated log record.
/// - *Bidi and invisible formatting* (U+202E and friends, zero-width marks, the
///   BOM, the line/paragraph separators) carry no control semantics at all —
///   they change how the surrounding text is **laid out**. Quoting them is
///   correct and useless. `heal`'s restore script rests entirely on "a human
///   reviews every executable line", and a right-to-left override rewrites that
///   line in the reviewer's editor while the shell reads it unchanged.
///
/// Both classes reach here from a card: `PathPlanner.sanitize` trims only the
/// *ends* of a component, so an interior control or override survives into the
/// destination filename, the manifest, the CSV and every report.
///
/// **What this is not.** It does not sanitize *storage*. The manifest and the
/// filesystem must record the name the file actually has, or verification stops
/// meaning anything. Neutralization belongs at the point of display.
enum SafeText {

    /// Untrusted text rendered safe for a terminal, a log line, or a shell
    /// comment. Escapes rather than drops, so the reader can still see what the
    /// odd filename actually contains — "this name has a right-to-left override
    /// in it" is exactly the fact they need.
    static func display(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if isControl(scalar) {
                    out += String(format: "\\x%02X", scalar.value)
                } else if isLayoutOverride(scalar) {
                    out += String(format: "\\u{%04X}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// True when `s` contains anything that survives correct quoting but defeats
    /// the human review of a generated shell line. `HealEngine` refuses to emit
    /// an executable line for such a path — the file is listed for a by-hand
    /// restore instead.
    static func containsDangerousControls(_ s: String) -> Bool {
        s.unicodeScalars.contains { isControl($0) || isLayoutOverride($0) }
    }

    /// C0, DEL, and C1. C1 is included because it is one byte away in Latin-1
    /// and some terminal emulators still act on it.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    /// Characters that reorder or hide the text around them rather than doing
    /// anything themselves: the bidi marks, embeddings, overrides and isolates;
    /// the zero-width space/joiner range; the invisible-operator range; the
    /// BOM/ZWNBSP; and the Unicode line and paragraph separators.
    private static func isLayoutOverride(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C,               // Arabic letter mark
             0x200B...0x200F,      // zero-width space/joiners, LRM, RLM
             0x2028...0x202E,      // line/paragraph separators, embeddings, overrides
             0x2060...0x2064,      // word joiner, invisible operators
             0x2066...0x2069,      // isolates
             0xFEFF:               // BOM / zero-width no-break space
            return true
        default:
            return false
        }
    }
}
