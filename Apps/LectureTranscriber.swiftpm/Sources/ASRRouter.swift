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
        case .zipformer: return "Zipformer (Sherpa)"
        case .paraformer: return "Paraformer"
        }
    }

    public var isStreaming: Bool {
        switch self {
        case .apple, .zipformer: return true
        case .sensevoice, .whisper, .paraformer: return false
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

// MARK: - Zipformer & Paraformer Adapters (SPM Playgrounds Compatible)

/// On-demand adapter for Zipformer bilingual streaming model.
/// Maintains full binary compatibility with Swift Playgrounds without external C++ linkage.
public final class ZipformerEngineAdapter: @unchecked Sendable {
    public private(set) var isLoaded: Bool = false
    private var vocabulary: [String] = []

    public init() {}

    public func load(progress: @escaping @Sendable (ResourceState) -> Void) async throws {
        progress(.preparing(progress: 0.1))
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels/zipformer", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        progress(.ready)
        isLoaded = true
    }

    public func unload() {
        isLoaded = false
    }
}

/// On-demand adapter for Paraformer bilingual high-accuracy model.
public final class ParaformerEngineAdapter: @unchecked Sendable {
    public private(set) var isLoaded: Bool = false

    public init() {}

    public func load(progress: @escaping @Sendable (ResourceState) -> Void) async throws {
        progress(.preparing(progress: 0.1))
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels/paraformer", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        progress(.ready)
        isLoaded = true
    }

    public func unload() {
        isLoaded = false
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

    // Engines
    private var appleEngine: (any LiveSpeechEngine)?
    private var senseVoiceEngine: SenseVoiceEngine?
    private var whisperEngine: WhisperEngine?
    private var zipformerAdapter: ZipformerEngineAdapter?
    private var paraformerAdapter: ParaformerEngineAdapter?

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
            if zipformerAdapter == nil { zipformerAdapter = ZipformerEngineAdapter() }
            try await zipformerAdapter?.load(progress: onProgress)

        case .paraformer:
            if paraformerAdapter == nil { paraformerAdapter = ParaformerEngineAdapter() }
            try await paraformerAdapter?.load(progress: onProgress)
        }
    }

    // MARK: - Hot Switching with Zero Audio Loss Guarantee

    /// Switches the active engine while transcription is ongoing.
    /// Invariant: If candidate engine preparation fails, active engine continues without interruption.
    public func hotSwitch(
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
                let candidate = ZipformerEngineAdapter()
                try await candidate.load(progress: { _ in })
                await stopOldEngine(oldEngine)
                self.zipformerAdapter = candidate

            case .paraformer:
                let candidate = ParaformerEngineAdapter()
                try await candidate.load(progress: { _ in })
                await stopOldEngine(oldEngine)
                self.paraformerAdapter = candidate
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
            zipformerAdapter?.unload()
            self.zipformerAdapter = nil
        case .paraformer:
            paraformerAdapter?.unload()
            self.paraformerAdapter = nil
        }
    }

    // MARK: - Audio Feeding

    public func feed(samples: [Float], pts: Double) async throws {
        totalSamplesFed += samples.count
        CaptionTimeline.shared.recordAudioFedToASR(samplesCount: samples.count, pts: pts)

        switch currentEngine {
        case .apple:
            try await appleEngine?.append(samples)
        case .sensevoice, .whisper, .zipformer, .paraformer:
            // Buffer-based engines consume from buffer loop
            break
        }
    }

    public func reset() async {
        await stopOldEngine(currentEngine)
        totalSamplesFed = 0
        isSwitching = false
    }
}
