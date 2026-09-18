import Foundation

/// Normalization layer providing reliable Simplified to Traditional Chinese conversion.
/// Preserves English, numbers, symbols, and formatting while falling back safely to the original text
/// if ICU/Foundation transforms are unavailable or fail.
public enum ChineseTextNormalizer {
    private static let simplifiedToTraditional = StringTransform("Simplified-Traditional")
    private static let hansToHant = StringTransform("Hans-Hant")

    /// Converts Simplified Chinese characters in `text` to Traditional Chinese.
    ///
    /// Requirements:
    /// - Transforms partial and final transcripts to Traditional Chinese.
    /// - Preserves English characters and words unchanged.
    /// - Preserves mixed Chinese and English text.
    /// - If transformation fails or returns an empty result for non-empty input, retains the original text.
    public static func toTraditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        if let converted = text.applyingTransform(simplifiedToTraditional, reverse: false), !converted.isEmpty {
            return converted
        }

        if let converted = text.applyingTransform(hansToHant, reverse: false), !converted.isEmpty {
            return converted
        }

        return text
    }
}
