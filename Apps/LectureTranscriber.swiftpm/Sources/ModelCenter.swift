import Foundation
import Combine

// MARK: - Model Manifest Item

public struct ModelManifestItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let engineType: ASREngineType
    public let downloadSizeMB: Double
    public let memoryEstimateMB: Double
    public let supportedLanguages: [String]
    public let supportsVocabularyBias: Bool
    public let isBuiltIn: Bool
    public let isExperimental: Bool
    public let isSupportedOnCurrentDevice: Bool
    public let unsupportedReason: String?

    public init(
        id: String,
        name: String,
        engineType: ASREngineType,
        downloadSizeMB: Double,
        memoryEstimateMB: Double,
        supportedLanguages: [String],
        supportsVocabularyBias: Bool,
        isBuiltIn: Bool = false,
        isExperimental: Bool = false,
        isSupportedOnCurrentDevice: Bool = true,
        unsupportedReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.engineType = engineType
        self.downloadSizeMB = downloadSizeMB
        self.memoryEstimateMB = memoryEstimateMB
        self.supportedLanguages = supportedLanguages
        self.supportsVocabularyBias = supportsVocabularyBias
        self.isBuiltIn = isBuiltIn
        self.isExperimental = isExperimental
        self.isSupportedOnCurrentDevice = isSupportedOnCurrentDevice
        self.unsupportedReason = unsupportedReason
    }
}

// MARK: - Model Center

@MainActor
public final class ModelCenter: ObservableObject {
    public static let shared = ModelCenter()

    @Published public private(set) var manifest: [ModelManifestItem] = []
    @Published public private(set) var modelStates: [String: ResourceState] = [:]

    private init() {
        populateManifest()
        refreshAllModelStates()
    }

    private func populateManifest() {
        manifest = [
            ModelManifestItem(
                id: "apple",
                name: "Apple Live Speech",
                engineType: .apple,
                downloadSizeMB: 0,
                memoryEstimateMB: 120,
                supportedLanguages: ["zh", "en"],
                supportsVocabularyBias: true,
                isBuiltIn: true,
                isExperimental: false,
                isSupportedOnCurrentDevice: {
                    if #available(iOS 26.0, *) { return true }
                    return false
                }(),
                unsupportedReason: "Requires iOS 26.0+"
            ),
            ModelManifestItem(
                id: "sensevoice-small",
                name: "SenseVoice Small (CoreML)",
                engineType: .sensevoice,
                downloadSizeMB: 240,
                memoryEstimateMB: 380,
                supportedLanguages: ["zh", "en", "ja", "ko", "yue"],
                supportsVocabularyBias: false,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "openai_whisper-large-v3-v20240930_626MB",
                name: "WhisperKit Large v3 Turbo",
                engineType: .whisper,
                downloadSizeMB: 626,
                memoryEstimateMB: 980,
                supportedLanguages: ["auto", "zh", "en", "ja", "ko", "es", "fr", "de"],
                supportsVocabularyBias: true,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "openai_whisper-small",
                name: "WhisperKit Small",
                engineType: .whisper,
                downloadSizeMB: 480,
                memoryEstimateMB: 650,
                supportedLanguages: ["auto", "zh", "en", "ja", "ko"],
                supportsVocabularyBias: true,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "openai_whisper-base",
                name: "WhisperKit Base",
                engineType: .whisper,
                downloadSizeMB: 145,
                memoryEstimateMB: 280,
                supportedLanguages: ["auto", "zh", "en"],
                supportsVocabularyBias: true,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "zipformer-bilingual",
                name: "Zipformer Bilingual",
                engineType: .zipformer,
                downloadSizeMB: 48,
                memoryEstimateMB: 150,
                supportedLanguages: ["zh", "en"],
                supportsVocabularyBias: false,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "paraformer-bilingual",
                name: "Streaming Paraformer Bilingual",
                engineType: .paraformer,
                downloadSizeMB: 226,
                memoryEstimateMB: 340,
                supportedLanguages: ["zh", "en"],
                supportsVocabularyBias: false,
                isBuiltIn: false,
                isExperimental: false,
                isSupportedOnCurrentDevice: true
            ),
            ModelManifestItem(
                id: "moonshine-base",
                name: "Moonshine Base (Experimental)",
                engineType: .whisper,
                downloadSizeMB: 120,
                memoryEstimateMB: 220,
                supportedLanguages: ["en"],
                supportsVocabularyBias: false,
                isBuiltIn: false,
                isExperimental: true,
                isSupportedOnCurrentDevice: false,
                unsupportedReason: "Moonshine experimental runtime deferred to v1.9.2"
            ),
            ModelManifestItem(
                id: "qwen3-asr",
                name: "Qwen3-ASR (Experimental)",
                engineType: .whisper,
                downloadSizeMB: 1200,
                memoryEstimateMB: 2400,
                supportedLanguages: ["zh", "en"],
                supportsVocabularyBias: false,
                isBuiltIn: false,
                isExperimental: true,
                isSupportedOnCurrentDevice: false,
                unsupportedReason: L10n.tr(
                    "LectureTranscriber 尚未整合可用的 iOS 裝置端執行環境",
                    "An iOS on-device runtime has not yet been integrated into LectureTranscriber."
                )
            )
        ]
    }

    public func state(for modelId: String) -> ResourceState {
        if let item = manifest.first(where: { $0.id == modelId }) {
            if item.isBuiltIn { return .ready }
            if !item.isSupportedOnCurrentDevice {
                return .failed(item.unsupportedReason ?? "Unsupported")
            }
        }
        return modelStates[modelId] ?? (isModelDownloaded(modelId) ? .ready : .notDownloaded)
    }

    public func isModelDownloaded(_ modelId: String) -> Bool {
        if modelId == "apple" { return true }
        guard let item = manifest.first(where: { $0.id == modelId }), item.isSupportedOnCurrentDevice else {
            return false
        }
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("SpeechModels", isDirectory: true) else { return false }

        if modelId == "sensevoice-small" {
            let path = base.appendingPathComponent("SenseVoice-CoreML-cdea3526163035c19915d4a10268992d018ebd46")
            return FileManager.default.fileExists(atPath: path.path)
        }

        if modelId == "zipformer-bilingual" {
            return ZipformerStreamingEngine.isModelInstalled()
        }

        if modelId == "paraformer-bilingual" {
            return ParaformerStreamingEngine.isModelInstalled()
        }

        let cacheFile = base.appendingPathComponent(modelId + "-location.txt")
        if let relative = try? String(contentsOf: cacheFile, encoding: .utf8),
           FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path) {
            return true
        }

        let folder = base.appendingPathComponent(modelId)
        return FileManager.default.fileExists(atPath: folder.path)
    }

    public func refreshAllModelStates() {
        for item in manifest {
            if item.isBuiltIn {
                modelStates[item.id] = .ready
            } else if !item.isSupportedOnCurrentDevice {
                modelStates[item.id] = .failed(item.unsupportedReason ?? "Unsupported")
            } else if isModelDownloaded(item.id) {
                modelStates[item.id] = .ready
            } else if modelStates[item.id] == nil {
                modelStates[item.id] = .notDownloaded
            }
        }
    }

    public func deleteModel(_ modelId: String) throws {
        guard let item = manifest.first(where: { $0.id == modelId }), !item.isBuiltIn, item.isSupportedOnCurrentDevice else { return }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("SpeechModels", isDirectory: true)

        if modelId == "zipformer-bilingual" {
            if let dir = ZipformerStreamingEngine.modelDirectory() {
                try? FileManager.default.removeItem(at: dir)
            }
        } else if modelId == "paraformer-bilingual" {
            if let dir = ParaformerStreamingEngine.modelDirectory() {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        let target = base.appendingPathComponent(modelId)
        let cacheFile = base.appendingPathComponent(modelId + "-location.txt")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: cacheFile)

        modelStates[modelId] = .notDownloaded
    }
}
