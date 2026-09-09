import Foundation
import AVFoundation
import Speech
import CoreMedia

struct SpeechUpdate: Sendable {
    let text: String
    let start: Double
    let end: Double
    let finalizedThrough: Double
    let isFinal: Bool
}

@MainActor
protocol LiveSpeechEngine: AnyObject {
    func prepare(language: String) async throws
    func start(language: String, onResult: @escaping @MainActor (SpeechUpdate) -> Void) async throws
    func append(_ samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}

@available(iOS 26.0, *)
@MainActor
final class AppleSpeechEngine: LiveSpeechEngine {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var failure: Error?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var preparedLanguage: String?

    func prepare(language: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw LectureError.message("這台裝置尚無法使用 Apple SpeechTranscriber；可在錄音設定切換 WhisperKit。")
        }
        guard language != "auto" else {
            throw LectureError.message("Apple 即時引擎需要指定主要語言，請選中文、英文，或設定中英夾雜的主要語言。")
        }
        if preparedLanguage == language, transcriber != nil { return }
        let requested = Locale(identifier: RecognitionLanguage.primary(language) == "en" ? "en-US" : "zh-TW")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw LectureError.message("Apple 即時引擎目前不支援所選語言 \(requested.identifier)。請改用 WhisperKit；不會擅自改成其他中文地區。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat) else {
            throw LectureError.message("Apple 語音資源尚未就緒，請保持連網並重新載入模型。")
        }
        transcriber = module; outputFormat = format; preparedLanguage = language
    }

    func start(language: String, onResult: @escaping @MainActor (SpeechUpdate) -> Void) async throws {
        await cancel()
        try await prepare(language: language)
        guard let transcriber, let outputFormat else { throw LectureError.message("Apple 語音模型未就緒。") }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard converter != nil else { throw LectureError.message("無法轉換 Apple 語音引擎需要的音訊格式。") }
        converter?.primeMethod = .none
        failure = nil
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
        continuation = builder
        let processor = SpeechAnalyzer(modules: [transcriber])
        analyzer = processor
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    onResult(SpeechUpdate(text: String(result.text.characters),
                        start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                        finalizedThrough: result.resultsFinalizationTime.seconds, isFinal: result.isFinal))
                }
            } catch { self?.failure = error; throw error }
        }
        try await processor.prepareToAnalyze(in: outputFormat)
        try await processor.start(inputSequence: stream)
    }

    func append(_ samples: [Float]) async throws {
        if let failure { throw failure }
        guard !samples.isEmpty else { return }
        guard let converter, let outputFormat,
              let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw LectureError.message("Apple 語音輸入尚未啟動。")
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { source.floatChannelData![0].update(from: base, count: samples.count) }
        }
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * outputFormat.sampleRate / 16000)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw LectureError.message("無法配置語音轉換緩衝區。")
        }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        if let error { throw error }
        guard status != .error else { throw LectureError.message("Apple 語音格式轉換失敗。") }
        if output.frameLength > 0 { try await enqueue(output) }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) async throws {
        let input = AnalyzerInput(buffer: buffer)
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard let continuation else { throw LectureError.message("Apple 語音串流已關閉，錄音可補辨識。") }
            switch continuation.yield(input) {
            case .enqueued: return
            case .dropped:
                // bufferingOldest rejects the newest input: retry it without losing audio.
                try await Task.sleep(nanoseconds: 25_000_000)
            case .terminated: throw LectureError.message("Apple 語音串流已結束，錄音可補辨識。")
            @unknown default: throw LectureError.message("Apple 語音串流狀態不明。")
            }
        }
    }

    func finish() async throws {
        guard let analyzer else { return }
        if let converter, let outputFormat {
            // Flush any resampler tail before ending the input stream.
            for _ in 0..<4 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                if let error { throw error }
                if status == .error { throw LectureError.message("語音轉換尾段未完成，請補辨識。") }
                if buffer.frameLength > 0 { try await enqueue(buffer) }
                if status == .endOfStream || buffer.frameLength == 0 { break }
            }
        }
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        if let failure { throw failure }
        self.analyzer = nil; continuation = nil; resultsTask = nil; converter = nil
        transcriber = nil; preparedLanguage = nil
    }

    func cancel() async {
        continuation?.finish(); resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        _ = try? await resultsTask?.value
        analyzer = nil; continuation = nil; resultsTask = nil; converter = nil
        transcriber = nil; preparedLanguage = nil; failure = nil
    }
}
