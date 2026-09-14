import Foundation

public struct SegmentMerger: Sendable {
    /// Common dangling word endings or connectors that indicate an incomplete thought when at the end of a line.
    public static let danglingEndings: [String] = [
        "going to", "want to", "need to", "able to", "have to", "has to", "had to",
        "to", "and", "that", "of", "with", "in", "on", "at", "for", "from",
        "as", "by", "about", "into", "through", "after", "over", "between",
        "out", "against", "during", "without", "before", "under", "around",
        "among", "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "being", "have", "has", "had", "we're", "i'm", "they're", "you're",
        "it's", "because", "although", "while", "if", "or", "but"
    ]

    /// Checks if a string ends with a dangling clause / connector.
    public static func isDangling(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        for ending in danglingEndings {
            if trimmed == ending || trimmed.hasSuffix(" " + ending) {
                return true
            }
        }
        return false
    }

    /// Checks if line A ends with a dangling clause or lacks terminal punctuation while line B starts with a lowercase word.
    public static func shouldMerge(previous: String, next: String) -> Bool {
        let prevTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTrimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prevTrimmed.isEmpty, !nextTrimmed.isEmpty else { return false }

        // If previous ends with terminal punctuation (. ? ! 。 ？ ！), do not merge.
        if let lastChar = prevTrimmed.last, [".", "?", "!", "。", "？", "！"].contains(lastChar) {
            return false
        }

        // Check if previous ends with a dangling phrase
        if isDangling(prevTrimmed) {
            return true
        }

        // If next starts with a lowercase letter, it's likely a continuation of an unpunctuated clause
        if let firstChar = nextTrimmed.first, firstChar.isLowercase {
            return true
        }

        return false
    }

    /// Checks if previous line should merge into next line, considering pause duration (< 3.0s).
    public static func shouldMerge(previous: TranscriptLine, next: TranscriptLine) -> Bool {
        guard next.start - previous.end < 3.0 else { return false }
        return shouldMerge(previous: previous.text, next: next.text)
    }

    /// Merges two segments into a single coherent text string.
    public static func mergeText(previous: String, next: String) -> String {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let nxt = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty else { return nxt }
        guard !nxt.isEmpty else { return prev }

        // If either previous ends with CJK or next starts with CJK, merge without space
        if let last = prev.last, let first = nxt.first,
           (isCJK(last) || isCJK(first)) {
            return prev + nxt
        }
        return prev + " " + nxt
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3000...0x303F).contains(scalar.value)
    }

    /// Checks if an ASR draft partial has reached a stable meaningful threshold (>=2 words or >=4 characters).
    public static func isMeaningfulDraft(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 4 {
            return true
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.count >= 2
    }
}
