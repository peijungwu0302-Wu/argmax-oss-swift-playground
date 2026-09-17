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
    public typealias RuntimeValidator = @Sendable (String, URL) async throws -> Void
    public var runtimeValidator: RuntimeValidator?
    public typealias ModelDownloader = @Sendable (String, @escaping @Sendable (Double?) -> Void) async throws -> Void
    public var customDownloader: ModelDownloader?

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

    public func installModel(modelId: String, from stagingDir: URL) async throws {
        guard let item = manifest.first(where: { $0.id == modelId }), !item.isBuiltIn, item.isSupportedOnCurrentDevice else {
            throw LectureError.message("此模型不支援安裝。")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SpeechModels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let targetFolderName: String
        let requiredFiles: [String]
        if modelId == "zipformer-bilingual" {
            targetFolderName = "sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16"
            requiredFiles = [
                "encoder-epoch-99-avg-1.int8.onnx",
                "decoder-epoch-99-avg-1.onnx",
                "joiner-epoch-99-avg-1.int8.onnx",
                "tokens.txt"
            ]
        } else if modelId == "paraformer-bilingual" {
            targetFolderName = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
            requiredFiles = [
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "tokens.txt"
            ]
        } else {
            throw LectureError.message("暫不支援安裝此模型：\(modelId)")
        }

        // 1. Verify required filenames and non-empty sizes in stagingDir
        for fileName in requiredFiles {
            let fileURL = stagingDir.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw LectureError.message("缺少必要模型檔案：\(fileName)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw LectureError.message("模型檔案無效或為空：\(fileName)")
            }
        }

        // 2. Atomic placement & runtime verification
        let targetDir = base.appendingPathComponent(targetFolderName, isDirectory: true)
        let backupDir = base.appendingPathComponent("\(targetFolderName).old-\(UUID().uuidString)")
        var didBackup = false
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.moveItem(at: targetDir, to: backupDir)
            didBackup = true
        }

        do {
            try FileManager.default.moveItem(at: stagingDir, to: targetDir)

            // 3. Runtime initialization validation
            if let customValidator = runtimeValidator {
                try await customValidator(modelId, targetDir)
            } else if SherpaOnnxRuntime.isSupported {
                let validator = SherpaOnnxRuntime()
                defer { Task { await validator.unload() } }

                if modelId == "zipformer-bilingual" {
                    let enc = targetDir.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path
                    let dec = targetDir.appendingPathComponent(ZipformerStreamingEngine.resolvedDecoderName(in: targetDir)).path
                    let joi = targetDir.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path
                    let tok = targetDir.appendingPathComponent("tokens.txt").path
                    try await validator.initZipformer(encoder: enc, decoder: dec, joiner: joi, tokens: tok)
                } else if modelId == "paraformer-bilingual" {
                    let enc = targetDir.appendingPathComponent("encoder.int8.onnx").path
                    let dec = targetDir.appendingPathComponent("decoder.int8.onnx").path
                    let tok = targetDir.appendingPathComponent("tokens.txt").path
                    try await validator.initParaformer(encoder: enc, decoder: dec, tokens: tok)
                }
                await validator.unload()
            }

            // Success: remove backup directory and assign .ready
            if didBackup {
                try? FileManager.default.removeItem(at: backupDir)
            }
            modelStates[modelId] = .ready
        } catch {
            // Failure: remove bad target directory, restore backup if it existed
            if FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.removeItem(at: targetDir)
            }
            if didBackup {
                try? FileManager.default.moveItem(at: backupDir, to: targetDir)
                modelStates[modelId] = .ready
            } else {
                modelStates[modelId] = .notDownloaded
            }
            throw error
        }
    }

    public func downloadModel(
        _ modelId: String,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws {
        guard let item = manifest.first(where: { $0.id == modelId }), !item.isBuiltIn, item.isSupportedOnCurrentDevice else {
            throw LectureError.message("此模型不支援下載。")
        }

        modelStates[modelId] = .downloading(bytesReceived: 0, totalBytes: 0, progress: 0)
        if let customDownloader {
            try await customDownloader(modelId, progress)
            if modelStates[modelId] == nil || !modelStates[modelId]!.isReady {
                modelStates[modelId] = .ready
            }
            return
        }

        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let files: [(String, String)]
        if modelId == "zipformer-bilingual" {
            files = [
                ("encoder-epoch-99-avg-1.int8.onnx", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16/resolve/main/encoder-epoch-99-avg-1.int8.onnx"),
                ("decoder-epoch-99-avg-1.onnx", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16/resolve/main/decoder-epoch-99-avg-1.onnx"),
                ("joiner-epoch-99-avg-1.int8.onnx", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16/resolve/main/joiner-epoch-99-avg-1.int8.onnx"),
                ("tokens.txt", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16/resolve/main/tokens.txt")
            ]
        } else if modelId == "paraformer-bilingual" {
            files = [
                ("encoder.int8.onnx", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/encoder.int8.onnx"),
                ("decoder.int8.onnx", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/decoder.int8.onnx"),
                ("tokens.txt", "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/main/tokens.txt")
            ]
        } else {
            throw LectureError.message("暫不支援在此處下載模型：\(modelId)")
        }

        let total = files.count
        var completed = 0
        for (fileName, urlString) in files {
            try Task.checkCancellation()
            guard let url = URL(string: urlString) else {
                throw LectureError.message("模型下載網址無效：\(urlString)")
            }
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw LectureError.message("下載模型檔案失敗：\(fileName)")
            }
            let dest = stagingDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            completed += 1
            let fraction = Double(completed) / Double(total)
            progress(fraction)
            modelStates[modelId] = .downloading(bytesReceived: Int64(completed), totalBytes: Int64(total), progress: fraction)
        }

        try await installModel(modelId: modelId, from: stagingDir)
    }

    public func deleteModel(_ modelId: String) throws {
        guard let item = manifest.first(where: { $0.id == modelId }), !item.isBuiltIn, item.isSupportedOnCurrentDevice else { return }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("SpeechModels", isDirectory: true)

        if modelId == "zipformer-bilingual" {
            let dir1 = base.appendingPathComponent("sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20", isDirectory: true)
            let dir2 = base.appendingPathComponent("sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16", isDirectory: true)
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        } else if modelId == "paraformer-bilingual" {
            let dir = base.appendingPathComponent("sherpa-onnx-streaming-paraformer-bilingual-zh-en", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }

        let target = base.appendingPathComponent(modelId)
        let cacheFile = base.appendingPathComponent(modelId + "-location.txt")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: cacheFile)

        modelStates[modelId] = .notDownloaded
    }
}
