import Foundation
import os

/// User-configurable destination naming. Two templates: the **day-folder**
/// name (the leaf under a fixed `{yyyy}/` year folder) and the primary **file**
/// stem (the original extension is always re-appended, so the file type is
/// preserved).
///
/// Syntax:
///   • `{…}` — a token. A known *named* token (Description, OriginalName,
///     OriginalStem, CardLabel) or, failing that, a Unicode date-format
///     pattern applied to the capture date (e.g. `{yyyy-MM-dd}`,
///     `{yyyyMMdd_HHmmss}`).
///   • `[…]` — an optional group: dropped entirely if a *named* token inside
///     it resolves empty (so `[_{Description}]` vanishes when there's no
///     description). Date tokens are never empty.
struct NamingTemplate: Sendable, Hashable {
    var folder: String
    var filename: String
    /// Whether a `{yyyy}` folder is inserted above the rendered day folder.
    ///
    /// This used to be unconditional — the year was a fixed top level and the
    /// folder template only ever described what sat *below* it. That made the
    /// most obvious layout of all, `{root}/2026-05-28/IMG_0001.jpg`,
    /// inexpressible no matter what you typed. It stays **on** by default: an
    /// existing library must keep landing exactly where it always has.
    ///
    /// With it off, depth is entirely the template author's business —
    /// `{yyyy}/{MM}/{yyyy-MM-dd}` nests three levels, `{yyyy-MM-dd}` nests one.
    var yearFolder: Bool = true

    static let `default` = NamingTemplate(
        folder: "{yyyy-MM-dd}[_{Description}]",
        filename: "{yyyyMMdd_HHmmss}_{OriginalStem}"
    )

    struct TokenHelp: Identifiable, Sendable {
        var id: String { token }
        let token: String
        let meaning: String
    }

    /// Tokens shown in the settings legend. (Date patterns are open-ended, so
    /// only the common ones are listed.)
    static let legend: [TokenHelp] = [
        TokenHelp(token: "{yyyy-MM-dd}", meaning: "Capture date — any date pattern works"),
        TokenHelp(token: "{HHmmss}", meaning: "Capture time"),
        TokenHelp(token: "{Description}", meaning: "The description field"),
        TokenHelp(token: "{OriginalStem}", meaning: "Original name, no extension"),
        TokenHelp(token: "{OriginalName}", meaning: "Original name with extension"),
        TokenHelp(token: "{CardLabel}", meaning: "Memory-card volume name"),
        TokenHelp(token: "{CameraModel}", meaning: "Camera model, from EXIF"),
        TokenHelp(token: "{BodySerial}", meaning: "Camera body serial number, from EXIF"),
        TokenHelp(token: "{Sequence:4}", meaning: "Position in this ingest, zero-padded (0001)"),
        TokenHelp(token: "[…]", meaning: "Optional — dropped if a named token inside is empty"),
    ]

    /// A fixed sample capture used to preview templates in the UI. Internal so
    /// `FolderLayout` renders its advertised sample through the same renderer
    /// the engine uses — an advertised path that doesn't match what the copy
    /// does would be a lie exactly where the user is choosing what to trust.
    static var sampleContext: TemplateContext {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28
        c.hour = 19; c.minute = 55; c.second = 10
        let date = Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
        return TemplateContext(
            date: date,
            description: PathPlanner.sanitize("Iceland"),
            originalName: "L1031253.DNG",
            originalStem: "L1031253",
            cardLabel: PathPlanner.sanitize("LEICA DLUX8")
        )
    }

    /// A representative destination path for the given templates, rendered
    /// exactly as the copy engine would (render → sanitize). Shown live as the
    /// user edits, in both Settings → Naming and the inspector, so the two can't
    /// drift. Pure.
    static func samplePath(folder: String, filename: String, yearFolder: Bool = true) -> String {
        "…/" + relativeSamplePath(folder: folder, filename: filename,
                                  yearFolder: yearFolder, context: sampleContext)
    }

    /// The sample path relative to the destination root, built the way
    /// `CopyPlan.destinationDirectory` builds a real one: render → sanitize,
    /// year level only when asked for.
    static func relativeSamplePath(folder: String, filename: String, yearFolder: Bool,
                                   context: TemplateContext, fileExtension: String = "DNG") -> String {
        let leaf = PathPlanner.sanitizedComponents(TemplateRenderer.render(folder, context))
        let stem = PathPlanner.sanitize(TemplateRenderer.render(filename, context))
        let safeLeaf = leaf.isEmpty
            ? [ISO8601DateFormatter.sampleDay(context.date)]
            : leaf
        let safeStem = stem.isEmpty ? "20260528_195510_L1031253" : stem
        let year = Calendar.current.component(.year, from: context.date)
        let components = (yearFolder ? [String(year)] : []) + safeLeaf
        return (components + ["\(safeStem).\(fileExtension)"]).joined(separator: "/")
    }
}

/// The per-bundle values a template renders against.
struct TemplateContext: Sendable {
    let date: Date
    let description: String   // already sanitized
    let originalName: String
    let originalStem: String
    let cardLabel: String     // sanitized; "" if unknown
    /// The camera body's model name, from EXIF. Empty when unknown.
    ///
    /// Two bodies shooting one wedding both write `IMG_0001.CR2` and both fire at
    /// 14:30:12, so the default template renders them to the same name and
    /// `CopyPlan` correctly pushes the second to `_1`. Nothing is overwritten —
    /// but the `_1` is assigned by *card ingest order*, so the two frames are then
    /// indistinguishable by name, and the same photo can carry a different name in
    /// two libraries ingested in a different order. The intended escape hatch was
    /// `{CardLabel}`, and cards ship and reformat as `UNTITLED`.
    let cameraModel: String
    /// The body's serial number, from EXIF. Empty when unknown. This is the token
    /// that actually separates two identical bodies; `cameraModel` does not.
    let bodySerial: String
    /// 1-based position of this file within the job, in plan order.
    ///
    /// Sequence numbering is the most common professional rename in this category
    /// and was inexpressible: `Wedding_0001, Wedding_0002…` could not be written
    /// however the templates were arranged. Zero-padded by repeating the token —
    /// `{Sequence}` → `1`, `{SSSS}`-style padding is spelled `{Sequence:4}` → `0001`.
    let sequence: Int

    /// Everything except the per-file parts, for callers that build one context
    /// per bundle from a shared job context.
    init(date: Date, description: String, originalName: String, originalStem: String,
         cardLabel: String, cameraModel: String = "", bodySerial: String = "", sequence: Int = 0) {
        self.date = date
        self.description = description
        self.originalName = originalName
        self.originalStem = originalStem
        self.cardLabel = cardLabel
        self.cameraModel = cameraModel
        self.bodySerial = bodySerial
        self.sequence = sequence
    }
}

enum TemplateRenderer {
    /// Render `template` against `context`. Top-level tokens always render;
    /// `[…]` groups drop when they contain an empty named token. The result is
    /// raw — callers sanitize it into a path component.
    static func render(_ template: String, _ context: TemplateContext) -> String {
        var out = ""
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            if ch == "[", let close = template[index...].firstIndex(of: "]") {
                let inner = String(template[template.index(after: index)..<close])
                let segment = renderSegment(inner, context)
                if !segment.hadEmptyNamed { out += segment.text }
                index = template.index(after: close)
            } else if ch == "{", let close = template[index...].firstIndex(of: "}") {
                let token = String(template[template.index(after: index)..<close])
                out += resolve(token, context).value
                index = template.index(after: close)
            } else {
                out.append(ch)
                index = template.index(after: index)
            }
        }
        return out
    }

    private static func renderSegment(_ segment: String, _ context: TemplateContext) -> (text: String, hadEmptyNamed: Bool) {
        var out = ""
        var hadEmptyNamed = false
        var index = segment.startIndex
        while index < segment.endIndex {
            let ch = segment[index]
            if ch == "{", let close = segment[index...].firstIndex(of: "}") {
                let token = String(segment[segment.index(after: index)..<close])
                let resolved = resolve(token, context)
                if resolved.isNamedEmpty { hadEmptyNamed = true }
                out += resolved.value
                index = segment.index(after: close)
            } else {
                out.append(ch)
                index = segment.index(after: index)
            }
        }
        return (out, hadEmptyNamed)
    }

    private static func resolve(_ token: String, _ context: TemplateContext) -> (value: String, isNamedEmpty: Bool) {
        switch token {
        case "Description":  return (context.description, context.description.isEmpty)
        case "OriginalName": return (context.originalName, context.originalName.isEmpty)
        case "OriginalStem": return (context.originalStem, context.originalStem.isEmpty)
        case "CardLabel":    return (context.cardLabel, context.cardLabel.isEmpty)
        case "CameraModel":  return (context.cameraModel, context.cameraModel.isEmpty)
        case "BodySerial":   return (context.bodySerial, context.bodySerial.isEmpty)
        case "Sequence":     return sequenceValue(context.sequence, width: 1)
        default:
            // `{Sequence:4}` — zero-padded to the given width. Parsed here rather
            // than added to the known-token list so the width is part of the token
            // rather than a second syntax.
            if token.hasPrefix("Sequence:"),
               let width = Int(token.dropFirst("Sequence:".count)), (1...12).contains(width) {
                return sequenceValue(context.sequence, width: width)
            }
            // A token that isn't a known name is a date-format pattern — but only
            // if it actually looks like one.
            //
            // Every unrecognized token used to be handed straight to
            // `DateFormatter`, which treats most ASCII letters as reserved
            // pattern characters and answers with digits. Measured:
            // `{Descripton}` (one missing `i`) rendered `14854052026`,
            // `{Description }` with a trailing space the same, `{Wedding}` → `5528`,
            // `{Shoot}` → `07`. A typo in the one field whose whole job is to name
            // the user's folders produced plausible-looking garbage in every
            // folder name on the card, with no error anywhere.
            //
            // It also returned `isNamedEmpty: false` unconditionally, so tokens
            // that rendered *empty* (`{Camera}`, `{Trip}`) didn't drop their
            // optional group either: `[_{Camera}]` left a bare `_` on every folder.
            guard isDatePattern(token) else { return ("", true) }
            return (Self.format(context.date, pattern: token), false)
        }
    }

    /// The date-format characters this app supports, plus the punctuation and
    /// literals that can sit between them.
    ///
    /// A whitelist rather than a blacklist: `DateFormatter` reserves nearly every
    /// ASCII letter, so "which letters are safe to pass through" is a far shorter
    /// and far more stable list than "which letters mean something surprising".
    private static let datePatternLetters = Set("yYMdDHhmsSaEZzGwWFkKquLcvVxX")

    /// True when `token` is plausibly a date-format pattern. Quoted literals
    /// (`'at'`) are accepted wholesale, matching `DateFormatter`'s own syntax.
    static func isDatePattern(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var inQuote = false
        var sawPatternLetter = false
        for ch in token {
            if ch == "'" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch.isLetter {
                guard datePatternLetters.contains(ch) else { return false }
                sawPatternLetter = true
            }
        }
        // A token of pure punctuation (`{-}`) is not a date pattern either; it
        // would render as itself, which the user can write literally.
        return sawPatternLetter && !inQuote
    }

    /// True when a *filename* template contains nothing that varies between two
    /// photos taken in the same second.
    ///
    /// `{OriginalName}` / `{OriginalStem}` are the only per-file tokens; a date
    /// pattern distinguishes photos only down to its finest unit. So
    /// `{yyyy-MM-dd}` gives every photo of a day one name, and the Settings
    /// legend advertises `{HHmmss}` and `{Description}` as standalone tokens
    /// without hinting at that. The result isn't data loss — collision-safe
    /// naming still gives each file its own path — but the names are
    /// `…_1`, `…_2`, … `…_797`, which carry no information and are not what
    /// anyone intends. Worth a warning; not worth refusing.
    static func lacksPerFileToken(_ template: String) -> Bool {
        !template.contains("{OriginalName}") && !template.contains("{OriginalStem}")
    }

    /// Tokens in `template` that resolve to neither a known name nor a date
    /// pattern — what Settings shows the user so a typo is visible before it
    /// names a thousand folders.
    static func unknownTokens(in template: String) -> [String] {
        var found: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{", let close = template[index...].firstIndex(of: "}") else {
                index = template.index(after: index)
                continue
            }
            let token = String(template[template.index(after: index)..<close])
            let known = ["Description", "OriginalName", "OriginalStem", "CardLabel",
                         "CameraModel", "BodySerial", "Sequence"]
            let isPaddedSequence = token.hasPrefix("Sequence:")
                && Int(token.dropFirst("Sequence:".count)).map { (1...12).contains($0) } == true
            if !known.contains(token), !isPaddedSequence, !isDatePattern(token), !found.contains(token) {
                found.append(token)
            }
            index = template.index(after: close)
        }
        return found
    }

    /// A sequence number is *empty* when the job never set one (0), so an
    /// optional group containing it drops rather than rendering a bare `0`.
    private static func sequenceValue(_ value: Int, width: Int) -> (value: String, isNamedEmpty: Bool) {
        guard value > 0 else { return ("", true) }
        return (String(format: "%0\(width)d", value), false)
    }

    /// Formats `date` with a cached `DateFormatter` for `pattern`.
    ///
    /// There are only ever a handful of distinct patterns in a job — the folder
    /// and filename templates — but `resolve` runs per token, per bundle, per
    /// destination root, and `PathPlanner`/`CopyPlan` each render again. A
    /// thousand-shot card across three destinations was constructing thousands
    /// of the single most expensive object in Foundation for this purpose.
    ///
    /// `DateFormatter` is not thread-safe, so the formatting happens *inside*
    /// the lock rather than the instance being handed back out — the format call
    /// is microseconds, far cheaper than the allocation it replaces. The cache
    /// is unbounded, which is fine: the key space is the set of patterns the user
    /// has typed. The current time zone is part of the key so a formatter built
    /// before the system zone changed is never reused after it.
    private static let formatters =
        OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    private static func format(_ date: Date, pattern: String) -> String {
        let zone = TimeZone.current
        let key = "\(zone.identifier)\u{0}\(pattern)"
        return formatters.withLock { cache in
            let formatter: DateFormatter
            if let existing = cache[key] {
                formatter = existing
            } else {
                formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = zone
                formatter.dateFormat = pattern
                cache[key] = formatter
            }
            return formatter.string(from: date)
        }
    }
}

extension ISO8601DateFormatter {
    /// `yyyy-MM-dd` for a date, used only as the fallback folder name when a
    /// template renders nothing usable. Matches `CopyPlan.destinationDirectory`.
    static func sampleDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }
}
