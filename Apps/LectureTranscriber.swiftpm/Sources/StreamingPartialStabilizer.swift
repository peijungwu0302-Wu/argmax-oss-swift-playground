import Foundation

/// Stabilizer for streaming ASR partial hypotheses (Zipformer, Paraformer).
///
/// Ensures subtitles advance smoothly and monotonically without visual flickering caused by
/// whole-line replacements or repetitive hypothesis emissions.
///
/// Features:
/// - Character / grapheme-safe comparisons.
/// - Suppresses duplicate emissions when the model returns an identical hypothesis.
/// - Immediately emits strict monotonic forward extensions.
/// - Handles minor tail revisions by preserving the stable common prefix and updating only the unstable tail.
/// - Suppresses pure backward shrinkage jitter.
/// - Resets cleanly after final transcripts, with finals strictly adhering to the model's output.
@MainActor
public final class StreamingPartialStabilizer {
    /// The last text emitted to presentation surfaces.
    public private(set) var lastEmittedText: String = ""

    /// The current stable prefix identified from recent hypotheses.
    public private(set) var stablePrefix: String = ""

    /// The unstable tail from the latest hypothesis.
    public private(set) var unstableTail: String = ""

    public init() {}

    /// Processes a live streaming partial hypothesis.
    ///
    /// - Parameter hypothesis: The latest partial transcription from ASR.
    /// - Returns: The stabilized string to emit to `LiveCaptionSyncController`,
    ///   or `nil` if the hypothesis is identical or should be suppressed to prevent visual flickering.
    @discardableResult
    public func processPartial(_ hypothesis: String) -> String? {
        let trimmed = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Initial emission for a new utterance
        if lastEmittedText.isEmpty {
            lastEmittedText = trimmed
            stablePrefix = trimmed
            unstableTail = ""
            return trimmed
        }

        // Rule 1: Suppress identical hypothesis repetitions
        if trimmed == lastEmittedText {
            return nil
        }

        let prevChars = Array(lastEmittedText)
        let newChars = Array(trimmed)

        // Find longest common prefix using Character (extended grapheme cluster) comparison
        var commonLength = 0
        while commonLength < prevChars.count &&
              commonLength < newChars.count &&
              prevChars[commonLength] == newChars[commonLength] {
            commonLength += 1
        }

        // Rule 2: Suppress temporary backward shrinkage jitter
        // If the model temporarily drops trailing characters without offering an alternative tail,
        // keep the previously emitted text to prevent visual bouncing.
        if commonLength == newChars.count && newChars.count < prevChars.count {
            return nil
        }

        // Rule 3: Strict forward extension or tail revision
        let common = String(newChars.prefix(commonLength))
        let tail = String(newChars.dropFirst(commonLength))

        let stabilized = common + tail
        lastEmittedText = stabilized
        stablePrefix = common
        unstableTail = tail

        return stabilized
    }

    /// Processes a finalized transcript line.
    /// Final transcripts are always strictly authoritative. Resets the stabilizer for the next utterance.
    ///
    /// - Parameter text: The final transcript text from the model.
    /// - Returns: The authoritative final text.
    @discardableResult
    public func processFinal(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        return trimmed
    }

    /// Resets all internal stabilizer state.
    public func reset() {
        lastEmittedText = ""
        stablePrefix = ""
        unstableTail = ""
    }
}
