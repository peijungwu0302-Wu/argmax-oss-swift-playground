import Foundation
import AVFoundation
import Speech
import CoreMedia

// MARK: - ASR Engine Identifier

public enum ASREngineType: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple = "apple"
    case sensevoice = "sensevoice"
    case whisper = "whisper"
    case zipformer = "zipformer"
    case paraformer = "paraformer"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple Live Speech"
        case .sensevoice: return "SenseVoice Small"
        case .whisper: return "WhisperKit"
        case .zipformer: return "Zipformer Bilingual"
        case .paraformer: return "Streaming Paraformer Bilingual"
        }
    }

    public var isAvailableInCurrentRelease: Bool {
        switch self {
        case .apple, .sensevoice, .whisper, .zipformer, .paraformer: return true
        }
    }

    public var isStreaming: Bool {
        switch self {
        case .apple, .zipformer, .paraformer: return true
        case .sensevoice, .whisper: return false
        }
    }

    public var supportsContextualVocabulary: Bool {
        switch self {
        case .apple, .whisper: return true
        case .sensevoice, .zipformer, .paraformer: return false
        }
    }
}

// MARK: - ASR Switch Event

public struct ASRSwitchEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let fromEngine: String
    public let toEngine: String
    public let sampleIndex: Int
    public let timestamp: TimeInterval
    public let createdAt: Date
    public let successful: Bool
    public let note: String?

    public init(
        id: UUID = UUID(),
        fromEngine: String,
        toEngine: String,
        sampleIndex: Int,
        timestamp: TimeInterval,
        createdAt: Date = Date(),
        successful: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.fromEngine = fromEngine
        self.toEngine = toEngine
        self.sampleIndex = sampleIndex
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.successful = successful
        self.note = note
    }
}

// MARK: - ASR Router

/// Centralized ASR engine orchestrator and hot-switching manager.
/// Core Principle: Engine switching must NEVER drop captured audio.
/// If candidate engine fails to prepare or start, the ACTIVE ENGINE STAYS RUNNING.
@MainActor
public final class ASRRouter: ObservableObject {
    public static let shared = ASRRouter()

    @Published public private(set) var currentEngine: ASREngineType = .apple
    @Published public private(set) var isSwitching: Bool = false
    @Published public private(set) var lastSwitchEvent: ASRSwitchEvent?
    @Published public private(set) var switchHistory: [ASRSwitchEvent] = []

    // Active Engines
    private var appleEngine: (any LiveSpeechEngine)?
    private var senseVoiceEngine: SenseVoiceEngine?
    private var whisperEngine: WhisperEngine?
    private var zipformerEngine: ZipformerStreamingEngine?
    private var paraformerEngine: ParaformerStreamingEngine?

    // Active streaming parameters
    private var activeLanguage: String = "zh"
    private var activeModelName: String = "openai_whisper-large-v3-v20240930_626MB"
    private var totalSamplesFed: Int = 0

    private init() {}

    // MARK: - Engine Initialization

    public func prepareEngine(
        _ type: ASREngineType,
        language: String,
        modelName: String? = nil,
        onProgress: @escaping @Sendable (ResourceState) -> Void
    ) async throws {
        switch type {
        case .apple:
            guard #available(iOS 26.0, *) else {
                throw LectureError.message("Apple Speech requires iOS 26.0+")
            }
            let engine = AppleSpeechEngine()
            try await engine.prepare(language: language) { progress in
                onProgress(.preparing(progress: progress))
            }
            onProgress(.ready)

        case .sensevoice:
            if senseVoiceEngine == nil { senseVoiceEngine = SenseVoiceEngine() }
            try await senseVoiceEngine?.load(language: language, progressState: onProgress)

        case .whisper:
            if whisperEngine == nil { whisperEngine = WhisperEngine() }
            let model = modelName ?? activeModelName
            try await whisperEngine?.load(model, progressState: onProgress)

        case .zipformer:
            if zipformerEngine == nil { zipformerEngine = ZipformerStreamingEngine() }
            try await zipformerEngine?.prepare(language: language) { progress in
                onProgress(.preparing(progress: progress))
            }
            onProgress(.ready)

        case .paraformer:
            if paraformerEngine == nil { paraformerEngine = ParaformerStreamingEngine() }
            try await paraformerEngine?.prepare(language: language) { progress in
                onProgress(.preparing(progress: progress))
            }
            onProgress(.ready)
        }
    }

    // MARK: - Hot Switching with Zero Audio Loss Guarantee

    /// Switches the active engine while transcription is ongoing.
    /// Invariant: If candidate engine preparation fails, active engine continues without interruption.
    func hotSwitch(
        to newType: ASREngineType,
        targetLanguage: String,
        modelName: String? = nil,
        currentSampleOffset: Int,
        currentPTS: Double,
        onResult: @escaping @MainActor (SpeechUpdate) -> Void
    ) async throws {
        guard newType != currentEngine || targetLanguage != activeLanguage else { return }
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        let oldEngine = currentEngine

        do {
            // 1. Prepare and test candidate engine in background WITHOUT stopping old engine
            switch newType {
            case .apple:
                guard #available(iOS 26.0, *) else {
                    throw LectureError.message("Apple Speech requires iOS 26.0+")
                }
                let candidate = AppleSpeechEngine()
                try await candidate.prepare(language: targetLanguage) { _ in }
                try await candidate.start(language: targetLanguage, onResult: onResult)
                // Drain old engine
                await stopOldEngine(oldEngine)
                self.appleEngine = candidate

            case .sensevoice:
                let candidate = SenseVoiceEngine()
                try await candidate.load(language: targetLanguage, progressState: { _ in })
                await stopOldEngine(oldEngine)
                self.senseVoiceEngine = candidate

            case .whisper:
                let candidate = WhisperEngine()
                let targetModel = modelName ?? activeModelName
                try await candidate.load(targetModel, progressState: { _ in })
                await stopOldEngine(oldEngine)
                self.whisperEngine = candidate

            case .zipformer:
                let candidate = ZipformerStreamingEngine()
                try await candidate.prepare(language: targetLanguage) { _ in }
                try await candidate.start(language: targetLanguage, onResult: onResult)
                await stopOldEngine(oldEngine)
                self.zipformerEngine = candidate

            case .paraformer:
                let candidate = ParaformerStreamingEngine()
                try await candidate.prepare(language: targetLanguage) { _ in }
                try await candidate.start(language: targetLanguage, onResult: onResult)
                await stopOldEngine(oldEngine)
                self.paraformerEngine = candidate
            }

            // 2. Candidate started successfully! Update pointers and record switch event
            self.currentEngine = newType
            self.activeLanguage = targetLanguage
            if let modelName { self.activeModelName = modelName }

            let event = ASRSwitchEvent(
                fromEngine: oldEngine.displayName,
                toEngine: newType.displayName,
                sampleIndex: currentSampleOffset,
                timestamp: currentPTS,
                successful: true,
                note: "Switched language to \(targetLanguage)"
            )
            self.lastSwitchEvent = event
            self.switchHistory.append(event)

        } catch {
            // Invariant maintained: oldEngine is still running!
            let failureEvent = ASRSwitchEvent(
                fromEngine: oldEngine.displayName,
                toEngine: newType.displayName,
                sampleIndex: currentSampleOffset,
                timestamp: currentPTS,
                successful: false,
                note: error.localizedDescription
            )
            self.lastSwitchEvent = failureEvent
            self.switchHistory.append(failureEvent)
            throw error
        }
    }

    private func stopOldEngine(_ engine: ASREngineType) async {
        switch engine {
        case .apple:
            if let appleEngine {
                try? await appleEngine.finish()
                await appleEngine.cancel()
            }
            self.appleEngine = nil
        case .sensevoice:
            await senseVoiceEngine?.unload()
            self.senseVoiceEngine = nil
        case .whisper:
            await whisperEngine?.unload()
            self.whisperEngine = nil
        case .zipformer:
            if let zipformerEngine {
                try? await zipformerEngine.finish()
                await zipformerEngine.cancel()
            }
            self.zipformerEngine = nil
        case .paraformer:
            if let paraformerEngine {
                try? await paraformerEngine.finish()
                await paraformerEngine.cancel()
            }
            self.paraformerEngine = nil
        }
    }

    // MARK: - Audio Feeding

    public func feed(samples: [Float], pts: Double) async throws {
        totalSamplesFed += samples.count
        CaptionTimeline.shared.recordAudioFedToASR(samplesCount: samples.count, pts: pts)

        switch currentEngine {
        case .apple:
            try await appleEngine?.append(samples)
        case .zipformer:
            try await zipformerEngine?.append(samples)
        case .paraformer:
            try await paraformerEngine?.append(samples)
        case .sensevoice, .whisper:
            // Buffer-based engines consume from circular buffer loop
            break
        }
    }

    public func reset() async {
        await stopOldEngine(currentEngine)
        totalSamplesFed = 0
        isSwitching = false
    }

    public func recordSwitch(
        from oldEngineName: String,
        to newEngineName: String,
        sampleIndex: Int,
        timestamp: Double,
        successful: Bool,
        note: String? = nil
    ) {
        let event = ASRSwitchEvent(
            fromEngine: oldEngineName,
            toEngine: newEngineName,
            sampleIndex: sampleIndex,
            timestamp: timestamp,
            successful: successful,
            note: note
        )
        self.lastSwitchEvent = event
        self.switchHistory.append(event)
        if successful, let type = ASREngineType(rawValue: newEngineName) {
            self.currentEngine = type
        }
    }

    // MARK: - Authoritative Switch & Cursor Planning

    public nonisolated static func planSwitch(
        from oldEngine: String,
        to newEngine: String,
        capturedSamples: Int,
        fedCursor: Int,
        finalizedCursor: Int
    ) -> ASRSwitchPlan {
        ASRSwitchPlan(
            oldEngine: oldEngine,
            newEngine: newEngine,
            capturedSampleCount: capturedSamples,
            oldEngineFedCursor: fedCursor,
            oldEngineFinalizedCursor: finalizedCursor,
            switchBoundary: capturedSamples
        )
    }
}

// MARK: - Switch Plan Structure

public struct ASRSwitchPlan: Equatable, Sendable {
    public let oldEngine: String
    public let newEngine: String
    public let capturedSampleCount: Int
    public let oldEngineFedCursor: Int
    public let oldEngineFinalizedCursor: Int
    public let switchBoundary: Int
    public let oldEngineCommittedRange: Range<Int>
    public let handoffBacklogRange: Range<Int>
    public let newEngineStartCursor: Int

    public init(
        oldEngine: String,
        newEngine: String,
        capturedSampleCount: Int,
        oldEngineFedCursor: Int,
        oldEngineFinalizedCursor: Int,
        switchBoundary: Int
    ) {
        self.oldEngine = oldEngine
        self.newEngine = newEngine
        self.capturedSampleCount = capturedSampleCount
        self.oldEngineFedCursor = oldEngineFedCursor
        self.oldEngineFinalizedCursor = oldEngineFinalizedCursor
        self.switchBoundary = switchBoundary

        // Audio already confirmed/finalized by old engine
        let committedEnd = max(0, min(oldEngineFinalizedCursor, switchBoundary))
        self.oldEngineCommittedRange = 0 ..< committedEnd

        // Audio captured up to switchBoundary that has not yet been finalized
        self.handoffBacklogRange = committedEnd ..< switchBoundary

        // New engine starts decoding/consuming from committedEnd
        self.newEngineStartCursor = committedEnd
    }

    /// Verifies that there is zero gap and zero overlap between committed audio and handoff backlog
    public var isValidHandoff: Bool {
        oldEngineCommittedRange.upperBound == handoffBacklogRange.lowerBound &&
        handoffBacklogRange.upperBound == switchBoundary
    }
}
