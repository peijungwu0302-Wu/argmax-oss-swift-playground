import Foundation

// MARK: - Vocabulary Entry Data Model

public struct VocabularyEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var canonical: String
    public var aliases: [String]

    public init(id: UUID = UUID(), canonical: String, aliases: [String] = []) {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
    }

    public var aliasesDisplayString: String {
        aliases.joined(separator: ", ")
    }
}

// MARK: - Course Vocabulary Store

@MainActor
public final class CourseVocabulary: ObservableObject {
    public static let shared = CourseVocabulary()
    public static let maxEntriesCount = 100
    public static let storageKey = "LectureTranscriber_CourseVocabulary_v1"

    @Published public private(set) var entries: [VocabularyEntry] = []

    private init() {
        load()
    }

    public func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    @discardableResult
    public func addEntry(canonical: String, aliases: [String] = []) -> Bool {
        guard entries.count < Self.maxEntriesCount else { return false }
        let cleanCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCanonical.isEmpty else { return false }
        let cleanAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(cleanCanonical) != .orderedSame }
        let entry = VocabularyEntry(canonical: cleanCanonical, aliases: cleanAliases)
        entries.append(entry)
        save()
        return true
    }

    public func updateEntry(id: UUID, canonical: String, aliases: [String]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let cleanCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCanonical.isEmpty else { return }
        let cleanAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(cleanCanonical) != .orderedSame }
        entries[index] = VocabularyEntry(id: id, canonical: cleanCanonical, aliases: cleanAliases)
        save()
    }

    public func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    public func setEntriesForTesting(_ testEntries: [VocabularyEntry]) {
        self.entries = Array(testEntries.prefix(Self.maxEntriesCount))
        save()
    }

    /// Canonical terms for Apple Speech contextual bias (e.g. contextualStrings).
    public var canonicalTerms: [String] {
        entries.map(\.canonical).filter { !$0.isEmpty }
    }

    /// Conservative word/phrase-boundary post-ASR replacement on stable/final text.
    public nonisolated func correctFinalText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let currentEntries: [VocabularyEntry]
        if let data = UserDefaults.standard.data(forKey: "LectureTranscriber_CourseVocabulary_v1"),
           let decoded = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
            currentEntries = decoded
        } else {
            return text
        }
        return Self.applyVocabulary(to: text, entries: currentEntries)
    }

    /// Core conservative replacement algorithm.
    /// Replaces known aliases and wrong casings with canonical terms using boundary matching.
    /// Targets are matched in descending order of length to avoid prefix-collision.
    public nonisolated static func applyVocabulary(to text: String, entries: [VocabularyEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        // Collect pairs: (targetPhrase, canonicalTerm)
        var pairs: [(target: String, canonical: String)] = []
        for entry in entries {
            let canon = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canon.isEmpty else { continue }
            // Case-insensitive correction of canonical itself if casing differs
            pairs.append((canon, canon))
            for alias in entry.aliases {
                let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanAlias.isEmpty && cleanAlias.caseInsensitiveCompare(canon) != .orderedSame {
                    pairs.append((cleanAlias, canon))
                }
            }
        }

        // Sort pairs by target length descending (longest phrase matches first)
        pairs.sort { $0.target.count > $1.target.count }

        var result = text
        for pair in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: pair.target)
            // Word boundary regex: (?<![a-zA-Z0-9_])escaped(?![a-zA-Z0-9_])
            let pattern = "(?<![a-zA-Z0-9_])" + escaped + "(?![a-zA-Z0-9_])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                let template = NSRegularExpression.escapedTemplate(for: pair.canonical)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }
        return result
    }
}
