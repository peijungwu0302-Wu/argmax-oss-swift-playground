import Foundation
#if canImport(SherpaOnnx)
import SherpaOnnx
#endif

struct SherpaStreamResult: Sendable, Equatable {
    let text: String
    let tokens: [String]
    let timestamps: [Float]
    let isEndpoint: Bool
    let startSampleIndex: Int
    let endSampleIndex: Int

    init(
        text: String,
        tokens: [String] = [],
        timestamps: [Float] = [],
        isEndpoint: Bool,
        startSampleIndex: Int,
        endSampleIndex: Int
    ) {
        self.text = text
        self.tokens = tokens
        self.timestamps = timestamps
        self.isEndpoint = isEndpoint
        self.startSampleIndex = startSampleIndex
        self.endSampleIndex = endSampleIndex
    }
}

/// Thread-safe streaming actor wrapping sherpa-onnx online recognizer.
/// Guarantee: Never blocks audio capture callbacks or MainActor.
actor SherpaOnnxRuntime {
    static var isSupported: Bool {
        #if canImport(SherpaOnnx)
        return true
        #else
        return false
        #endif
    }

    #if canImport(SherpaOnnx)
    private var recognizer: SherpaOnnxRecognizer?
    #endif

    private var sampleCountFed: Int = 0
    private var segmentStartSample: Int = 0
    private var isInitialized: Bool = false
    private var activeModelId: String = ""

    init() {}

    var isReady: Bool {
        isInitialized
    }

    var currentModelId: String {
        activeModelId
    }

    /// Initializes a Zipformer transducer streaming recognizer.
    func initZipformer(
        encoder: String,
        decoder: String,
        joiner: String,
        tokens: String,
        numThreads: Int = 2,
        provider: String = "cpu"
    ) throws {
        #if canImport(SherpaOnnx)
        unload()

        guard FileManager.default.fileExists(atPath: encoder),
              FileManager.default.fileExists(atPath: decoder),
              FileManager.default.fileExists(atPath: joiner),
              FileManager.default.fileExists(atPath: tokens) else {
            throw LectureError.message("Zipformer 模型檔案缺失，請重新檢查模型路徑。")
        }

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokens,
            transducer: transducer,
            numThreads: numThreads,
            provider: provider
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.4,
            rule2MinTrailingSilence: 1.2,
            rule3MinUtteranceLength: 20.0,
            decodingMethod: "greedy_search"
        )

        let rec = SherpaOnnxRecognizer(config: &recognizerConfig)
        self.recognizer = rec
        self.sampleCountFed = 0
        self.segmentStartSample = 0
        self.isInitialized = true
        self.activeModelId = "zipformer-bilingual"
        #else
        throw LectureError.message("sherpa-onnx 執行環境未在目前平台啟用。")
        #endif
    }

    /// Initializes a Paraformer streaming recognizer.
    func initParaformer(
        encoder: String,
        decoder: String,
        tokens: String,
        numThreads: Int = 2,
        provider: String = "cpu"
    ) throws {
        #if canImport(SherpaOnnx)
        unload()

        guard FileManager.default.fileExists(atPath: encoder),
              FileManager.default.fileExists(atPath: decoder),
              FileManager.default.fileExists(atPath: tokens) else {
            throw LectureError.message("Paraformer 模型檔案缺失，請重新檢查模型路徑。")
        }

        let paraformer = sherpaOnnxOnlineParaformerModelConfig(
            encoder: encoder,
            decoder: decoder
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokens,
            paraformer: paraformer,
            numThreads: numThreads,
            provider: provider
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.4,
            rule2MinTrailingSilence: 1.2,
            rule3MinUtteranceLength: 20.0,
            decodingMethod: "greedy_search"
        )

        let rec = SherpaOnnxRecognizer(config: &recognizerConfig)
        self.recognizer = rec
        self.sampleCountFed = 0
        self.segmentStartSample = 0
        self.isInitialized = true
        self.activeModelId = "paraformer-bilingual"
        #else
        throw LectureError.message("sherpa-onnx 執行環境未在目前平台啟用。")
        #endif
    }

    /// Accepts 16 kHz Float samples, runs online decoding, and returns stream updates if ready.
    func acceptWaveform(samples: [Float], sampleRate: Int = 16000) -> SherpaStreamResult? {
        guard !samples.isEmpty else { return nil }
        #if canImport(SherpaOnnx)
        guard let recognizer else { return nil }

        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)
        sampleCountFed += samples.count

        while recognizer.isReady() {
            recognizer.decode()
        }

        let isEndpoint = recognizer.isEndpoint()
        let result = recognizer.getResult()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let streamResult = SherpaStreamResult(
            text: text,
            tokens: result.tokens,
            timestamps: result.timestamps,
            isEndpoint: isEndpoint,
            startSampleIndex: segmentStartSample,
            endSampleIndex: sampleCountFed
        )

        if isEndpoint {
            recognizer.reset()
            segmentStartSample = sampleCountFed
        }

        return streamResult
        #else
        return nil
        #endif
    }

    /// Flushes remaining audio at the end of recording.
    func finishStream() -> SherpaStreamResult? {
        #if canImport(SherpaOnnx)
        guard let recognizer else { return nil }
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }
        let result = recognizer.getResult()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamResult = SherpaStreamResult(
            text: text,
            tokens: result.tokens,
            timestamps: result.timestamps,
            isEndpoint: true,
            startSampleIndex: segmentStartSample,
            endSampleIndex: sampleCountFed
        )
        recognizer.reset()
        segmentStartSample = sampleCountFed
        return streamResult
        #else
        return nil
        #endif
    }

    /// Resets the stream state without destroying the loaded recognizer.
    func resetStream() {
        #if canImport(SherpaOnnx)
        recognizer?.reset()
        #endif
        segmentStartSample = sampleCountFed
    }

    /// Releases recognizer resources and clears memory.
    func unload() {
        #if canImport(SherpaOnnx)
        recognizer = nil
        #endif
        isInitialized = false
        activeModelId = ""
        sampleCountFed = 0
        segmentStartSample = 0
    }
}
