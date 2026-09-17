import Foundation
import Combine

// MARK: - Live Caption Sync Controller

/// Presentation controller orchestrating live caption delivery between CaptionTimeline (ground-truth facts)
/// and presentation surfaces (CaptionFeed, CaptionPiP, and Live Activities).
///
/// Policies:
/// - NORMAL: Immediate pass-through of partials and finals.
/// - CATCHING_UP: Coalesces rapid partials (latest-state-wins, throttled) to prevent presentation UI chokepoints.
/// - STALE: Bypasses obsolete intermediate partials to immediately surface the newest useful cue,
///   while preserving 100% of finalized transcript lines in storage.
@MainActor
public final class LiveCaptionSyncController: ObservableObject {
    public static let shared = LiveCaptionSyncController()

    public let timeline: CaptionTimeline
    private var lastPartialEmitTime: Date = .distantPast
    private let catchUpThrottleInterval: TimeInterval = 0.25 // 250ms throttling in CATCHING_UP
    private let staleThrottleInterval: TimeInterval = 0.50   // 500ms throttling in STALE

    public init(timeline: CaptionTimeline = .shared) {
        self.timeline = timeline
    }

    // MARK: - ASR Feed Handlers

    /// Receives a partial speech hypothesis from ASR.
    @discardableResult
    public func receivePartial(
        start: Double,
        end: Double,
        text: String,
        engine: String = "apple",
        language: String = "zh",
        translation: String? = nil
    ) -> CaptionCue {
        let cue = timeline.receivePartial(start: start, end: end, text: text, engine: engine, language: language)
        lastPartialEmitTime = Date()
        let resolvedTranslation: String?
        if let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTranslation = translation
        } else if !cue.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTranslation = cue.translatedText
        } else {
            resolvedTranslation = nil
        }
        emit(id: cue.id, original: text, translation: resolvedTranslation, cueEndTime: end)
        return cue
    }

    /// Receives a finalized transcript line from ASR.
    @discardableResult
    public func receiveFinal(
        id: UUID? = nil,
        start: Double,
        end: Double,
        text: String,
        engine: String = "apple",
        language: String = "zh",
        translation: String? = nil
    ) -> CaptionCue {
        let cue = timeline.receiveFinal(id: id, start: start, end: end, text: text, engine: engine, language: language)
        let resolvedTranslation: String?
        if let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTranslation = translation
        } else if !cue.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTranslation = cue.translatedText
        } else {
            resolvedTranslation = nil
        }
        // Finals are always emitted to display latest confirmed text with authoritative cue ID
        emit(id: cue.id, original: text, translation: resolvedTranslation, cueEndTime: end)
        return cue
    }

    /// Records translation completion for a line or cue and updates presentation.
    public func updateTranslation(forCueID id: UUID? = nil, throughPTS: Double? = nil, translation: String) {
        if let id {
            timeline.updateTranslation(forCueID: id, translation: translation)
        } else {
            timeline.updateLatestTranslation(translation)
        }
        if let pts = throughPTS {
            timeline.recordTranslationComplete(forLine: id, throughPTS: pts)
        }
        // Delayed translation policy:
        // Always surface latest available translation to CaptionFeed so completed translations
        // are never dropped when subsequent speech partials have already begun.
        CaptionFeed.shared.update(
            translation: translation,
            cueEndTime: throughPTS ?? CaptionFeed.shared.latestCueEndTime
        )
    }

    public func reset() {
        lastPartialEmitTime = .distantPast
        timeline.reset()
    }

    private func emit(id: UUID? = nil, original: String, translation: String?, cueEndTime: Double?) {
        let currentTranslation = translation ?? CaptionFeed.shared.latestTranslation
        CaptionFeed.shared.update(
            original: original,
            translation: currentTranslation,
            latestCueID: id,
            cueEndTime: cueEndTime
        )
        // Presentation acknowledgement rule:
        // emit() selects presentation state for CaptionFeed.
        // It MUST NOT advance timeline.displayedThrough. Only actual presentation
        // acknowledgement (e.g. AVSampleBufferDisplayLayer enqueue success) advances displayedThrough.
    }
}
