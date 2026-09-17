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

// MARK: - Snapshot Model

public struct CaptionTimelineSnapshot: Sendable, Equatable {
    public let syncState: CaptionSyncState
    public let capturedThrough: Double
    public let fedThrough: Double
    public let hypothesisThrough: Double
    public let recognizedThrough: Double
    public let translatedThrough: Double
    public let displayedThrough: Double
    public let presentationSurfaceActive: Bool

    // Media position lags (all within the media timeline)
    public let recognitionMediaLag: Double
    public let translationMediaLag: Double
    public let displayMediaLag: Double
    public let endToEndMediaLag: Double

    // Backward-compatible alias
    public var captureToASRLag: Double { recognitionMediaLag }

    public init(
        syncState: CaptionSyncState,
        capturedThrough: Double,
        fedThrough: Double,
        hypothesisThrough: Double = 0.0,
        recognizedThrough: Double,
        translatedThrough: Double,
        displayedThrough: Double,
        presentationSurfaceActive: Bool = false,
        recognitionMediaLag: Double,
        translationMediaLag: Double,
        displayMediaLag: Double,
        endToEndMediaLag: Double
    ) {
        self.syncState = syncState
        self.capturedThrough = capturedThrough
        self.fedThrough = fedThrough
        self.hypothesisThrough = hypothesisThrough
        self.recognizedThrough = recognizedThrough
        self.translatedThrough = translatedThrough
        self.displayedThrough = displayedThrough
        self.presentationSurfaceActive = presentationSurfaceActive
        self.recognitionMediaLag = recognitionMediaLag
        self.translationMediaLag = translationMediaLag
        self.displayMediaLag = displayMediaLag
        self.endToEndMediaLag = endToEndMediaLag
    }
}

// MARK: - Caption Synchronization Watermarks & Timeline

@MainActor
public final class CaptionTimeline: ObservableObject {
    public static let shared = CaptionTimeline()

    // Explicit single media timeline (capture-relative monotonic seconds)
    private var sessionEpochPTS: Double?

    @Published public private(set) var capturedThrough: Double = 0.0
    @Published public private(set) var fedThrough: Double = 0.0
    @Published public private(set) var hypothesisThrough: Double = 0.0
    @Published public private(set) var recognizedThrough: Double = 0.0
    @Published public private(set) var translatedThrough: Double = 0.0
    @Published public private(set) var displayedThrough: Double = 0.0
    @Published public var presentationSurfaceActive: Bool = false

    // Backward-compatible property aliases
    public var audioCapturedPTS: Double { capturedThrough }
    public var audioFedToASRPTS: Double { fedThrough }
    public var asrFinalizedPTS: Double { recognizedThrough }

    // Separate wall-clock processing durations (tracked separately; NEVER subtracted from media PTS)
    @Published public private(set) var lastASRProcessingDuration: Double?
    @Published public private(set) var lastTranslationProcessingDuration: Double?
    @Published public private(set) var lastDisplayRenderDuration: Double?

    @Published public private(set) var syncState: CaptionSyncState = .normal
    @Published public private(set) var cues: [CaptionCue] = []
    @Published public private(set) var activeCue: CaptionCue?

    private var revisionCounter: Int = 0

    public func setPresentationSurfaceActive(_ active: Bool) {
        presentationSurfaceActive = active
        updateSyncState()
    }

    // Sensible thresholds for catch-up and stale states
    private let catchUpEnterThreshold: Double = 1.2   // seconds of lag
    private let catchUpExitThreshold: Double = 0.35   // seconds of lag to return to normal
    private let staleThreshold: Double = 3.5          // seconds of display lag to declare stale

    // Media position lags
    public var recognitionMediaLag: Double {
        max(0.0, capturedThrough - recognizedThrough)
    }

    public var translationMediaLag: Double {
        max(0.0, recognizedThrough - translatedThrough)
    }

    public var displayMediaLag: Double {
        max(0.0, recognizedThrough - displayedThrough)
    }

    public var endToEndMediaLag: Double {
        max(0.0, capturedThrough - displayedThrough)
    }

    // Backward-compatible lag alias
    public var captureToASRLag: Double { recognitionMediaLag }

    public init() {}

    public func reset() {
        sessionEpochPTS = nil
        capturedThrough = 0.0
        fedThrough = 0.0
        hypothesisThrough = 0.0
        recognizedThrough = 0.0
        translatedThrough = 0.0
        displayedThrough = 0.0
        presentationSurfaceActive = false
        lastASRProcessingDuration = nil
        lastTranslationProcessingDuration = nil
        lastDisplayRenderDuration = nil
        syncState = .normal
        cues.removeAll()
        activeCue = nil
        revisionCounter = 0
    }

    // MARK: - Time Normalization

    private func normalize(pts: Double) -> Double {
        max(0.0, pts)
    }

    // MARK: - Watermark Updates

    public func recordAudioCaptured(duration: Double, pts: Double) {
        let normalized = normalize(pts: pts)
        capturedThrough = max(capturedThrough, normalized)
        updateSyncState()
    }

    public func recordCaptured(through timestamp: Double) {
        recordAudioCaptured(duration: 0, pts: timestamp)
    }

    public func recordAudioFedToASR(samplesCount: Int, pts: Double) {
        let normalized = normalize(pts: pts)
        fedThrough = max(fedThrough, normalized)
    }

    public func recordFedToASR(through timestamp: Double) {
        recordAudioFedToASR(samplesCount: 0, pts: timestamp)
    }

    public func recordASRFinalized(throughPTS: Double, wallClockDuration: Double? = nil) {
        let normalized = normalize(pts: throughPTS)
        hypothesisThrough = max(hypothesisThrough, normalized)
        recognizedThrough = max(recognizedThrough, normalized)
        if let duration = wallClockDuration {
            lastASRProcessingDuration = duration
        }
        updateSyncState()
    }

    public func recordRecognized(through timestamp: Double) {
        recordASRFinalized(throughPTS: timestamp)
    }

    public func recordTranslationComplete(forLine: UUID? = nil, throughPTS: Double? = nil, wallClockDuration: Double? = nil) {
        if let pts = throughPTS {
            let normalized = normalize(pts: pts)
            translatedThrough = max(translatedThrough, normalized)
        }
        if let duration = wallClockDuration {
            lastTranslationProcessingDuration = duration
        }
        updateSyncState()
    }

    public func recordTranslated(through timestamp: Double) {
        recordTranslationComplete(throughPTS: timestamp)
    }

    public func recordCaptionDisplayed(at wallClock: Double? = nil, throughPTS: Double? = nil) {
        if let pts = throughPTS {
            let normalized = normalize(pts: pts)
            displayedThrough = max(displayedThrough, normalized)
        }
        if let wallClock = wallClock {
            lastDisplayRenderDuration = wallClock
        }
        updateSyncState()
    }

    public func recordDisplayed(through timestamp: Double) {
        recordCaptionDisplayed(throughPTS: timestamp)
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
        hypothesisThrough = max(hypothesisThrough, normalize(pts: end))

        // In CATCHING_UP mode: latest-state-wins for partials
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
        id: UUID? = nil,
        start: Double,
        end: Double,
        text: String,
        engine: String,
        language: String
    ) -> CaptionCue {
        revisionCounter += 1
        recordASRFinalized(throughPTS: end)

        let finalCue = CaptionCue(
            id: id ?? UUID(),
            startTime: start,
            endTime: end,
            originalText: text,
            isFinal: true,
            revision: revisionCounter,
            engine: engine,
            language: language
        )
        // Finalized cues are NEVER dropped; history remains complete!
        cues.append(finalCue)
        activeCue = finalCue

        // Cap in-memory active timeline to recent window
        if cues.count > 100 {
            cues.removeFirst(cues.count - 100)
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

    /// Called when source media pauses: update sync state without fabricating progress
    public func drainBacklog() {
        updateSyncState()
    }

    private func updateSyncState() {
        let recLag = recognitionMediaLag
        let dispLag = presentationSurfaceActive ? displayMediaLag : 0.0

        if dispLag > staleThreshold {
            syncState = .stale
            // NEVER fabricate displayedThrough here; watermark strictly reflects actual rendered cue time
        } else if recLag > catchUpEnterThreshold || dispLag > catchUpEnterThreshold {
            syncState = .catchingUp
        } else if recLag <= catchUpExitThreshold && dispLag <= catchUpExitThreshold {
            syncState = .normal
        } else if syncState == .stale {
            // Once dispLag drops below staleThreshold, timeline is no longer stale
            syncState = .catchingUp
        }
    }

    public func snapshot() -> CaptionTimelineSnapshot {
        CaptionTimelineSnapshot(
            syncState: syncState,
            capturedThrough: capturedThrough,
            fedThrough: fedThrough,
            hypothesisThrough: hypothesisThrough,
            recognizedThrough: recognizedThrough,
            translatedThrough: translatedThrough,
            displayedThrough: displayedThrough,
            presentationSurfaceActive: presentationSurfaceActive,
            recognitionMediaLag: recognitionMediaLag,
            translationMediaLag: translationMediaLag,
            displayMediaLag: displayMediaLag,
            endToEndMediaLag: endToEndMediaLag
        )
    }

    public func formattedDiagnostics() -> String {
        """
        [Sync: \(syncState.rawValue)] (SurfaceActive: \(presentationSurfaceActive))
        Captured:   \(String(format: "%.2f s", capturedThrough))
        Fed ASR:    \(String(format: "%.2f s", fedThrough))
        Hypothesis: \(String(format: "%.2f s", hypothesisThrough))
        Recognized: \(String(format: "%.2f s", recognizedThrough))
        Translated: \(String(format: "%.2f s", translatedThrough))
        Displayed:  \(String(format: "%.2f s", displayedThrough))
        Media Lag:  Rec=\(String(format: "%.2f s", recognitionMediaLag)), Trans=\(String(format: "%.2f s", translationMediaLag)), Disp=\(String(format: "%.2f s", displayMediaLag)), E2E=\(String(format: "%.2f s", endToEndMediaLag))
        """
    }
}
