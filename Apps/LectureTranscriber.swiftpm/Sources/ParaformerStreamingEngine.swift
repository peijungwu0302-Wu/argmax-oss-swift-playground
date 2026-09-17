import Foundation
import AVFoundation

@MainActor
final class ParaformerStreamingEngine: LiveSpeechEngine {
    static let modelFolder = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
    static let encoderName = "encoder.int8.onnx"
    static let decoderName = "decoder.int8.onnx"
    static let tokensName = "tokens.txt"
    static var mockPrepareHandler: (@MainActor (String, @escaping @MainActor (Double?) -> Void) async throws -> Void)?

    private let runtime = SherpaOnnxRuntime()
    private var onResult: (@MainActor (SpeechUpdate) -> Void)?
    private var isPrepared: Bool = false

    init() {}

    static func modelDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("SpeechModels", isDirectory: true) else {
            return nil
        }
        return base.appendingPathComponent(modelFolder, isDirectory: true)
    }

    static func isModelInstalled() -> Bool {
        guard let dir = modelDirectory(), FileManager.default.fileExists(atPath: dir.path) else { return false }
        let enc = dir.appendingPathComponent(encoderName)
        let dec = dir.appendingPathComponent(decoderName)
        let tok = dir.appendingPathComponent(tokensName)
        guard FileManager.default.fileExists(atPath: enc.path) &&
              FileManager.default.fileExists(atPath: dec.path) &&
              FileManager.default.fileExists(atPath: tok.path) else { return false }

        let encSize = (try? FileManager.default.attributesOfItem(atPath: enc.path)[.size] as? NSNumber)?.intValue ?? 0
        let decSize = (try? FileManager.default.attributesOfItem(atPath: dec.path)[.size] as? NSNumber)?.intValue ?? 0
        let tokSize = (try? FileManager.default.attributesOfItem(atPath: tok.path)[.size] as? NSNumber)?.intValue ?? 0
        return encSize > 1024 && decSize > 1024 && tokSize > 0
    }

    func prepare(language: String, onProgress: @escaping @MainActor (Double?) -> Void) async throws {
        guard let dir = Self.modelDirectory(), Self.isModelInstalled() else {
            throw LectureError.message("Streaming Paraformer 模型尚未下載，請至模型中心下載後再使用。")
        }
        if let mock = Self.mockPrepareHandler {
            try await mock(language, onProgress)
            isPrepared = true
            return
        }
        guard SherpaOnnxRuntime.isSupported else {
            throw LectureError.message("此系統平台尚未支援 sherpa-onnx 執行環境。")
        }

        onProgress(0.2)
        let enc = dir.appendingPathComponent(Self.encoderName).path
        let dec = dir.appendingPathComponent(Self.decoderName).path
        let tok = dir.appendingPathComponent(Self.tokensName).path

        try await runtime.initParaformer(
            encoder: enc,
            decoder: dec,
            tokens: tok,
            numThreads: 2,
            provider: "cpu"
        )
        onProgress(1.0)
        isPrepared = true
    }

    func start(language: String, onResult: @escaping @MainActor (SpeechUpdate) -> Void) async throws {
        if !isPrepared {
            try await prepare(language: language, onProgress: { _ in })
        }
        await runtime.startNewStream()
        self.onResult = onResult
    }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let result = await runtime.acceptWaveform(samples: samples) else { return }

        // Factual segment-level media timing from sample indices. No fabricated token timestamps.
        let startPTS = Double(result.startSampleIndex) / 16000.0
        let endPTS = Double(result.endSampleIndex) / 16000.0

        if result.isEndpoint {
            if !result.text.isEmpty {
                let update = SpeechUpdate(
                    text: result.text,
                    start: startPTS,
                    end: endPTS,
                    finalizedThrough: endPTS,
                    isFinal: true
                )
                onResult?(update)
            }
        } else {
            if !result.text.isEmpty {
                let update = SpeechUpdate(
                    text: result.text,
                    start: startPTS,
                    end: endPTS,
                    finalizedThrough: startPTS,
                    isFinal: false
                )
                onResult?(update)
            }
        }
    }

    func finish() async throws {
        if let result = await runtime.finishStream() {
            let startPTS = Double(result.startSampleIndex) / 16000.0
            let endPTS = Double(result.endSampleIndex) / 16000.0
            if !result.text.isEmpty {
                let update = SpeechUpdate(
                    text: result.text,
                    start: startPTS,
                    end: endPTS,
                    finalizedThrough: endPTS,
                    isFinal: true
                )
                onResult?(update)
            }
        }
        onResult = nil
    }

    func cancel() async {
        await runtime.resetStream()
        onResult = nil
    }

    func unload() async {
        await runtime.unload()
        isPrepared = false
        onResult = nil
    }
}
