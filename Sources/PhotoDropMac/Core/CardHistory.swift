import Foundation

/// What has already been ingested from each card.
///
/// **The 2am problem.** A wedding is six cards from three bodies plus a second
/// shooter's cards arriving at midnight. The app modelled six unrelated events
/// and recorded nothing about any of them, so there was no way to answer "did I
/// already do this one?" except re-inserting the card, waiting out a full index
/// build and a full source-hash pass, and reading the result — which is both slow
/// and, at 2am, exactly when a person guesses instead.
///
/// This is not a queue and not a session. It is the smallest thing that removes
/// the ambiguity: the card's own volume UUID, when it was last ingested, how many
/// files landed, and where the receipt is.
///
/// **Keyed on the volume UUID, not the label**, because cards ship and reformat
/// as `UNTITLED` and a label collision would make two cards look like one. A
/// reformat mints a new UUID, which is the right behaviour — a reformatted card
/// genuinely is a new card, and the entry for the old one aging out is harmless.
struct CardHistoryEntry: Codable, Sendable, Equatable {
    let volumeID: String
    let label: String
    let ingestedAt: Date
    let filesLanded: Int
    /// Where the manifest for that job lives, so "show me the receipt" is one
    /// click rather than a hunt through `PhotoDrop Manifests/`.
    let manifestPath: String?
}

enum CardHistory {
    static let defaultsKey = "photodrop.cardHistory"

    /// Entries are pruned to this many, newest first. A photographer's card
    /// rotation is small and this is a convenience, not an archive — the
    /// manifests are the durable record.
    static let maxEntries = 60

    static func record(_ entry: CardHistoryEntry, in defaults: UserDefaults = .standard) {
        var entries = all(in: defaults).filter { $0.volumeID != entry.volumeID }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func all(in defaults: UserDefaults = .standard) -> [CardHistoryEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([CardHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func entry(forVolumeID id: String, in defaults: UserDefaults = .standard) -> CardHistoryEntry? {
        all(in: defaults).first { $0.volumeID == id }
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// "Ingested 23:41 tonight" / "Ingested 3 days ago" — deliberately relative,
    /// because the question being answered is "was this one of tonight's?".
    static func describe(_ entry: CardHistoryEntry, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: entry.ingestedAt, relativeTo: now)
        let files = entry.filesLanded == 1 ? "1 file" : "\(entry.filesLanded.formatted()) files"
        return "Ingested \(when) · \(files)"
    }
}
