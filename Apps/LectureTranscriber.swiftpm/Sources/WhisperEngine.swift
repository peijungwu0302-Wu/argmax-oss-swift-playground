import Foundation
@preconcurrency import WhisperKit

enum SpeechModel: String, CaseIterable, Identifiable {
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3-v20240930_626MB"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .base: return "Base · 較輕量"
        case .small: return "Small · 較輕量"
        case .turbo: return "Large v3 Turbo · 預設"
        }
    }
}
actor WhisperEngine {
    private var kit: WhisperKit?
    private var currentModel: String?
    func unload() { kit = nil; currentModel = nil }
    func load(_ model: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        if currentModel == model, kit != nil { return }
        kit = nil; currentModel = nil
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cacheFile = base.appendingPathComponent(model + "-location.txt")
        let folder: URL
        if let relative = try? String(contentsOf: cacheFile, encoding: .utf8),
           FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path) {
            folder = base.appendingPathComponent(relative)
        } else {
            progress("下載語音模型，首次使用需要網路…", 0)
            folder = try await WhisperKit.download(variant: model, downloadBase: base) { download in
                progress("正在下載語音模型…", download.fractionCompleted)
            }
            let relative = String(folder.path.dropFirst(base.path.count + 1))
            try relative.write(to: cacheFile, atomically: true, encoding: .utf8)
        }
        progress("正在準備裝置上的模型，首次可能需要幾分鐘…", nil)
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base,
            verbose: false, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        currentModel = model
        progress("模型已就緒", 1)
    }
    func transcribe(file: URL, start: Int, count: Int, offset: Double, language: String,
                    vocabulary: String, context: String, final: Bool,
                    onDraft: @escaping @Sendable (String, Int) -> Void) async throws -> [TranscriptLine] {
        guard let kit else { throw LectureError.message("請先載入語音模型。") }
        let samples = try PCMRecorder.read(file, from: start, count: count)
        guard !samples.isEmpty else { return [] }
        let rms = sqrt(samples.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(samples.count))
        if rms < 0.0001 { return [] }
        // Whisper accepts one language token, not a simultaneous zh+en language selection.
        // A Chinese-led mixed lecture uses zh plus a bilingual text prompt; task stays transcribe.
        let prompt = [language == "mixed" ? "這是中文與 English 的課堂記錄。" : "",
                      String(vocabulary.prefix(500)), String(context.suffix(160))]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let tokens = kit.tokenizer.map { Array($0.encode(text: prompt).suffix(160)) }
        let options = DecodingOptions(task: .transcribe,
            language: language == "auto" ? nil : (language == "mixed" ? "zh" : language),
            temperatureFallbackCount: final ? 2 : 1,
            usePrefillPrompt: true, detectLanguage: language == "auto",
            skipSpecialTokens: true, withoutTimestamps: false,
            wordTimestamps: false, windowClipTime: 0,
            promptTokens: prompt.isEmpty ? nil : tokens, concurrentWorkerCount: 1)
        let relay = DraftRelay(onDraft)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options) { progress in
            relay.publish(progress.text)
            return nil
        }
        let duration = Double(samples.count) / 16000
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let begin = min(duration, max(0, Double(segment.start)))
            let end = min(duration, max(begin, Double(segment.end)))
            guard end > begin else { return nil }
            return TranscriptLine(start: offset + begin, end: offset + end, text: text)
        }
    }
}

// Decoder callbacks can arrive off the main actor. Throttle UI work and number updates
// so a delayed callback can never overwrite a newer draft or a completed decode.
private final class DraftRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = Date.distantPast
    private var revision = 0
    private let callback: @Sendable (String, Int) -> Void
    init(_ callback: @escaping @Sendable (String, Int) -> Void) { self.callback = callback }
    func publish(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastTime) >= 0.15 else { return }
        let text = raw.replacingOccurrences(of: "<\\|[^>]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastTime = now; revision += 1
        callback(text, revision)
    }
}
