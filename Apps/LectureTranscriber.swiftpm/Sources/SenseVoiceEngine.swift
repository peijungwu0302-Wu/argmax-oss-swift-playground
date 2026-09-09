import Foundation
import CryptoKit
import SherpaOnnxC

/// Own the C recognizer rather than the upstream fatalError-based Swift wrapper.
/// Creation failures are recoverable; all access is serialized by SenseVoiceEngine.
private final class SenseVoiceHandle {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { SherpaOnnxDestroyOfflineRecognizer(pointer) }
}

actor SenseVoiceEngine {
    private var handle: SenseVoiceHandle?
    private var loadedLanguage: String?
    static let modelRevision = "2365baeacb507f821a0c8120fcee3d484dba7a07"
    private static let files: [(String, String)] = [
        ("model.int8.onnx", "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
        ("tokens.txt", "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc")
    ]

    func unload() { handle = nil; loadedLanguage = nil }

    func load(language: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let selected = SenseVoiceWindow.modelLanguage(language)
        if handle != nil, loadedLanguage == selected { return }
        unload()
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels/SenseVoiceSmall-INT8", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (name, digest) in Self.files {
            let target = base.appendingPathComponent(name)
            if Self.matches(target, digest: digest) { continue }
            progress("下載 SenseVoice（約 240 MB），首次使用需要網路…", nil)
            let address = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/\(Self.modelRevision)/\(name)"
            guard let url = URL(string: address) else { throw LectureError.message("SenseVoice 模型網址無效。") }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  Self.matches(temporary, digest: digest) else {
                throw LectureError.message("SenseVoice 下載未完成或檔案驗證失敗，請重新載入。")
            }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            var excluded = target
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
        }
        progress("正在準備 SenseVoice 中英辨識…", nil)
        try initialize(folder: base, language: selected)
        progress("SenseVoice 已就緒", 1)
    }

    // The benchmark calls the same initialization and decode path as the app.
    func initialize(folder: URL, language: String) throws {
        for (name, digest) in Self.files {
            guard Self.matches(folder.appendingPathComponent(name), digest: digest) else {
                throw LectureError.message("SenseVoice 模型檔案不完整，請重新下載。")
            }
        }
        unload()
        let selected = SenseVoiceWindow.modelLanguage(language)
        let pointer = folder.appendingPathComponent("model.int8.onnx").path.withCString { model in
            folder.appendingPathComponent("tokens.txt").path.withCString { tokens in
                selected.withCString { lang in
                    "cpu".withCString { provider in
                        "sense_voice".withCString { type in
                            "greedy_search".withCString { method in
                                var config = SherpaOnnxOfflineRecognizerConfig()
                                config.feat_config.sample_rate = 16000
                                config.feat_config.feature_dim = 80
                                config.model_config.tokens = tokens
                                config.model_config.num_threads = 2
                                config.model_config.provider = provider
                                config.model_config.model_type = type
                                config.model_config.sense_voice.model = model
                                config.model_config.sense_voice.language = lang
                                config.model_config.sense_voice.use_itn = 1
                                config.decoding_method = method
                                return SherpaOnnxCreateOfflineRecognizer(&config)
                            }
                        }
                    }
                }
            }
        }
        guard let pointer else { throw LectureError.message("無法初始化 SenseVoice，請關閉其他大型模型後重試。") }
        handle = SenseVoiceHandle(pointer); loadedLanguage = selected
    }

    func transcribe(_ samples: [Float]) throws -> String {
        try Task.checkCancellation()
        guard let handle else { throw LectureError.message("請先載入 SenseVoice 模型。") }
        guard !samples.isEmpty, samples.count <= SenseVoiceWindow.maximumSamples,
              samples.allSatisfy(\.isFinite) else { throw LectureError.message("SenseVoice 音訊範圍無效。") }
        guard let stream = SherpaOnnxCreateOfflineStream(handle.pointer) else {
            throw LectureError.message("無法建立 SenseVoice 辨識片段。")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(handle.pointer, stream)
        try Task.checkCancellation()
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw LectureError.message("SenseVoice 尚未產生結果；錄音仍保留。")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let raw = result.pointee.text.map { String(cString: $0) } ?? ""
        let cleaned = raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? cleaned
    }

    private static func matches(_ url: URL, digest: String) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        do {
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
        } catch { return false }
    }
}
