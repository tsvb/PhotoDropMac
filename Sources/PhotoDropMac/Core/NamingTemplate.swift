import Foundation

/// User-configurable destination naming, mirroring the Windows PhotoDrop
/// pattern. Two templates: the **day-folder** name (the leaf under a fixed
/// `{yyyy}/` year folder) and the primary **file** stem (the original
/// extension is always re-appended, so the file type is preserved).
///
/// Syntax:
///   • `{…}` — a token. A known *named* token (Description, OriginalName,
///     OriginalStem, CardLabel) or, failing that, a Unicode/.NET date-format
///     pattern applied to the capture date (e.g. `{yyyy-MM-dd}`,
///     `{yyyyMMdd_HHmmss}`).
///   • `[…]` — an optional group: dropped entirely if a *named* token inside
///     it resolves empty (so `[_{Description}]` vanishes when there's no
///     description). Date tokens are never empty.
struct NamingTemplate: Sendable, Equatable {
    var folder: String
    var filename: String

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
        TokenHelp(token: "[…]", meaning: "Optional — dropped if a named token inside is empty"),
    ]
}

/// The per-bundle values a template renders against.
struct TemplateContext: Sendable {
    let date: Date
    let description: String   // already sanitized
    let originalName: String
    let originalStem: String
    let cardLabel: String     // sanitized; "" if unknown
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
        default:
            // Anything else is treated as a date-format pattern.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = token
            return (formatter.string(from: context.date), false)
        }
    }
}
