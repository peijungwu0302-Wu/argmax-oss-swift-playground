import Foundation
import Combine

// MARK: - Caption Cue

public struct CaptionCue: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var startTime: Double
    public var endTime: Double
    public var originalText: String
    public var translatedText: String
    public var isFinal: Bool
    public var revision: Int
    public var engine: String
    public var language: String

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        originalText: String,
        translatedText: String = "",
        isFinal: Bool = false,
        revision: Int = 1,
        engine: String = "apple",
        language: String = "zh"
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.translatedText = translatedText
        self.isFinal = isFinal
        self.revision = revision
        self.engine = engine
        self.language = language
    }
}

// MARK: - Sync State

public enum CaptionSyncState: String, Sendable, Codable, Equatable {
    case normal = "NORMAL"
    case catchingUp = "CATCHING_UP"
    case stale = "STALE"
}

// MARK: - Caption Synchronization Watermarks & Timeline

@MainActor
public final class CaptionTimeline: ObservableObject {
    public static let shared = CaptionTimeline()

    @Published public private(set) var watermarkCapturedThrough: Double = 0.0
    @Published public private(set) var watermarkFedToASRThrough: Double = 0.0
    @Published public private(set) var watermarkRecognizedThrough: Double = 0.0
    @Published public private(set) var watermarkTranslatedThrough: Double = 0.0
    @Published public private(set) var watermarkDisplayedThrough: Double = 0.0

    @Published public private(set) var syncState: CaptionSyncState = .normal
    @Published public private(set) var cues: [CaptionCue] = []
    @Published public private(set) var activeCue: CaptionCue?

    private var revisionCounter: Int = 0

    // Sensible thresholds for catch-up and stale states
    private let catchUpEnterThreshold: Double = 1.2  // seconds of lag
    private let catchUpExitThreshold: Double = 0.35  // seconds of lag to return to normal
    private let staleThreshold: Double = 3.5         // seconds of display lag to declare stale

    public var recognitionLag: Double {
        max(0.0, watermarkCapturedThrough - watermarkRecognizedThrough)
    }

    public var translationLag: Double {
        max(0.0, watermarkRecognizedThrough - watermarkTranslatedThrough)
    }

    public var displayLag: Double {
        max(0.0, watermarkRecognizedThrough - watermarkDisplayedThrough)
    }

    public init() {}

    public func reset() {
        watermarkCapturedThrough = 0.0
        watermarkFedToASRThrough = 0.0
        watermarkRecognizedThrough = 0.0
        watermarkTranslatedThrough = 0.0
        watermarkDisplayedThrough = 0.0
        syncState = .normal
        cues.removeAll()
        activeCue = nil
        revisionCounter = 0
    }

    // MARK: - Watermark Updates

    public func recordCaptured(through timestamp: Double) {
        watermarkCapturedThrough = max(watermarkCapturedThrough, timestamp)
        updateSyncState()
    }

    public func recordFedToASR(through timestamp: Double) {
        watermarkFedToASRThrough = max(watermarkFedToASRThrough, timestamp)
    }

    public func recordRecognized(through timestamp: Double) {
        watermarkRecognizedThrough = max(watermarkRecognizedThrough, timestamp)
        updateSyncState()
    }

    public func recordTranslated(through timestamp: Double) {
        watermarkTranslatedThrough = max(watermarkTranslatedThrough, timestamp)
    }

    public func recordDisplayed(through timestamp: Double) {
        watermarkDisplayedThrough = max(watermarkDisplayedThrough, timestamp)
        updateSyncState()
    }

    // MARK: - Cue Management

    @discardableResult
    public func receivePartial(
        start: Double,
        end: Double,
        text: String,
        engine: String,
        language: String
    ) -> CaptionCue {
        revisionCounter += 1
        recordRecognized(through: end)

        // In CATCHING_UP mode: latest-state-wins for partials
        // We do not churn old intermediate partial cues
        if let existing = activeCue, !existing.isFinal {
            var updated = existing
            updated.endTime = max(existing.endTime, end)
            updated.originalText = text
            updated.revision = revisionCounter
            updated.engine = engine
            updated.language = language
            activeCue = updated
            return updated
        } else {
            let newCue = CaptionCue(
                startTime: start,
                endTime: end,
                originalText: text,
                isFinal: false,
                revision: revisionCounter,
                engine: engine,
                language: language
            )
            activeCue = newCue
            return newCue
        }
    }

    @discardableResult
    public func receiveFinal(
        start: Double,
        end: Double,
        text: String,
        engine: String,
        language: String
    ) -> CaptionCue {
        revisionCounter += 1
        recordRecognized(through: end)

        let finalCue = CaptionCue(
            startTime: start,
            endTime: end,
            originalText: text,
            isFinal: true,
            revision: revisionCounter,
            engine: engine,
            language: language
        )
        cues.append(finalCue)
        activeCue = finalCue

        // Cap in-memory active timeline to recent window (e.g. 50 cues)
        if cues.count > 50 {
            cues.removeFirst(cues.count - 50)
        }
        return finalCue
    }

    public func updateTranslation(forCueID id: UUID, translation: String) {
        if activeCue?.id == id {
            activeCue?.translatedText = translation
        }
        if let idx = cues.firstIndex(where: { $0.id == id }) {
            cues[idx].translatedText = translation
            recordTranslated(through: cues[idx].endTime)
        }
    }

    public func updateLatestTranslation(_ translation: String) {
        activeCue?.translatedText = translation
        if let lastFinal = cues.last {
            recordTranslated(through: lastFinal.endTime)
        }
    }

    // MARK: - Catch-Up & Stale Logic

    /// Called when source media pauses: aggressively drain backlog
    public func drainBacklog() {
        watermarkRecognizedThrough = watermarkCapturedThrough
        watermarkTranslatedThrough = watermarkRecognizedThrough
        updateSyncState()
    }

    private func updateSyncState() {
        let recLag = recognitionLag
        let dispLag = displayLag

        if dispLag > staleThreshold {
            syncState = .stale
            // Jump display forward toward newest recognized watermark
            watermarkDisplayedThrough = watermarkRecognizedThrough - 0.2
        } else if recLag > catchUpEnterThreshold || dispLag > catchUpEnterThreshold {
            syncState = .catchingUp
        } else if recLag <= catchUpExitThreshold && dispLag <= catchUpExitThreshold {
            syncState = .normal
        }
    }

    public func formattedDiagnostics() -> String {
        """
        [Sync: \(syncState.rawValue)]
        Captured: \(String(format: "%.2f s", watermarkCapturedThrough))
        Fed ASR:  \(String(format: "%.2f s", watermarkFedToASRThrough))
        Recognized: \(String(format: "%.2f s", watermarkRecognizedThrough))
        Translated: \(String(format: "%.2f s", watermarkTranslatedThrough))
        Displayed:  \(String(format: "%.2f s", watermarkDisplayedThrough))
        Lag: Rec=\(String(format: "%.2f s", recognitionLag)), Trans=\(String(format: "%.2f s", translationLag)), Disp=\(String(format: "%.2f s", displayLag))
        """
    }
}
