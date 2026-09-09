import Foundation
import CryptoKit
@preconcurrency import CoreML

// Core ML pipeline adapted from FluidInference/FluidAudio (Apache-2.0).
// See THIRD-PARTY-NOTICES.txt. No sherpa/ONNX binary package or unzip process.
actor SenseVoiceEngine {
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var vocabulary: [String] = []
    private var selectedLanguage: Int32 = 0
    private var buckets: [Int] = []
    // Simulator/macOS CI uses FP32 because the published INT8/FP16 graph
    // requires ANE and can produce non-finite logits under CPU fallback.
    #if targetEnvironment(simulator) || os(macOS)
    private let encoderName = "SenseVoiceSmall_fp32.mlmodelc"
    #else
    private let encoderName = "SenseVoiceSmall_int8.mlmodelc"
    #endif
    private static let revision = "cdea3526163035c19915d4a10268992d018ebd46"
    private static let files: [(String, Int, String)] = [
        ("SenseVoicePreprocessor.mlmodelc/analytics/coremldata.bin", 243, "5bdb0b132e48c7e852ec18eeba7e217b6cb7153e6a939ce76b5ed17242e956dd"),
        ("SenseVoicePreprocessor.mlmodelc/coremldata.bin", 330, "e64cc73b2a9b01bad799a23874bc20dba3cf3342c23e3f60012c3e884f682944"),
        ("SenseVoicePreprocessor.mlmodelc/model.mil", 15008, "1b9b18be0a35b11165269b1ca071a30af736deb314d8bd82d9540c769137a70e"),
        ("SenseVoicePreprocessor.mlmodelc/weights/weight.bin", 3037504, "69c630a115da5e4db36ec41662f0b776c0ef33ec6776d86f8cdaaba022518396"),
        ("SenseVoiceSmall_fp32.mlmodelc/analytics/coremldata.bin", 243, "09bdfe5eee1fd3cc70fc39e1e144ede5118e138c3c2dd52a2822d0d72fbb91f8"),
        ("SenseVoiceSmall_fp32.mlmodelc/coremldata.bin", 396, "ba5a1b5d9bf9b1b85ef2d1f69717e1f4424cc72e7316fc3edb0b604e449f9919"),
        ("SenseVoiceSmall_fp32.mlmodelc/model.mil", 915059, "4569b5ac67d69a50b993c1d3918e6d569f2d22b3a129653cc4e6c8f0c270cc9e"),
        ("SenseVoiceSmall_fp32.mlmodelc/weights/weight.bin", 940100992, "62919f3a37419a1e4ede3763d6efcf2ae9ed320e6bd9fb4a37d2b15ef891b92d"),
        ("SenseVoiceSmall_int8.mlmodelc/analytics/coremldata.bin", 243, "ab5e9ee0d49e1f88838f1c2178cbe58a20dac12b50c4da803a75a54c6229845a"),
        ("SenseVoiceSmall_int8.mlmodelc/coremldata.bin", 436, "55ef1c194e641418817d7d07f6bfbd8032571e800b81264caba37eb63a95335b"),
        ("SenseVoiceSmall_int8.mlmodelc/model.mil", 1134696, "015fe7242a15eeb2fc0ca7f908ca3a09a5826b36e7d7f704803c8bbe60c1a148"),
        ("SenseVoiceSmall_int8.mlmodelc/weights/weight.bin", 235373118, "dab122c65d5043cba5b47561d5c1d3a049dd123c662e802d9dbce8fdd0505a38"),
        ("vocab.json", 352064, "a2594fc1474e78973149cba8cd1f603ebed8c39c7decb470631f66e70ce58e97"),
    ]

    func unload() { preprocessor = nil; encoder = nil; vocabulary = []; buckets = [] }

    func load(language: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        selectedLanguage = languageIndex(language)
        if preprocessor != nil, encoder != nil { return }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels/SenseVoice-CoreML-" + Self.revision, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excludedRoot = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excludedRoot.setResourceValues(values)
        let files = Self.files.filter { $0.0.hasPrefix(encoderName + "/") || $0.0.hasPrefix("SenseVoicePreprocessor.mlmodelc/") || $0.0 == "vocab.json" }
        let total = files.reduce(0) { $0 + $1.1 }; var completed = 0
        for (path, size, digest) in files {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(path)
            if !Self.matches(destination, size: size, digest: digest) {
                progress("下載 SenseVoice Core ML（約 \(total / 1_000_000) MB），請保持 App 開啟…", Double(completed) / Double(total))
                let address = "https://huggingface.co/FluidInference/sensevoice-small-coreml/resolve/\(Self.revision)/\(path)"
                guard let url = URL(string: address) else { throw LectureError.message("模型網址無效。") }
                let (temporary, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      Self.matches(temporary, size: size, digest: digest) else {
                    throw LectureError.message("SenseVoice 模型下載或校驗未完成，請重新載入；已完成的檔案會保留。")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            completed += size
        }
        progress("正在準備 SenseVoice Core ML，首次載入可能需要幾分鐘…", nil)
        let front = MLModelConfiguration(); front.computeUnits = .cpuOnly
        let inference = MLModelConfiguration()
        #if targetEnvironment(simulator) || os(macOS)
        inference.computeUnits = .cpuOnly
        #else
        inference.computeUnits = .cpuAndNeuralEngine
        #endif
        let pre = try await MLModel.load(contentsOf: root.appendingPathComponent("SenseVoicePreprocessor.mlmodelc"), configuration: front)
        let enc = try await MLModel.load(contentsOf: root.appendingPathComponent(encoderName), configuration: inference)
        let vocab = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("vocab.json")))
        guard vocab.count == 25055,
              let constraint = enc.modelDescription.inputDescriptionsByName["speech"]?.multiArrayConstraint else {
            throw LectureError.message("SenseVoice 模型介面或詞表不相符。")
        }
        // Read shapes from the actual artifact: the FP32 fallback has a fixed
        // 1800-frame input, unlike the short enumerated INT8 buckets.
        let enumerated = constraint.shapeConstraint.enumeratedShapes
        let shapes = enumerated.isEmpty ? [constraint.shape] : enumerated
        let supported = shapes.filter { $0.count == 3 && $0[2].intValue == 560 }.map { $0[1].intValue }.sorted()
        guard !supported.isEmpty else { throw LectureError.message("SenseVoice 輸入尺寸不受支援。") }
        preprocessor = pre; encoder = enc; vocabulary = vocab; buckets = supported
        progress("SenseVoice Core ML 已就緒", 1)
    }

    func transcribe(_ samples: [Float]) throws -> String {
        try Task.checkCancellation()
        guard let preprocessor, let encoder else { throw LectureError.message("請先載入 SenseVoice 模型。") }
        guard !samples.isEmpty, samples.count <= SenseVoiceWindow.maximumSamples,
              samples.allSatisfy(\.isFinite) else { throw LectureError.message("SenseVoice 音訊範圍無效。") }
        return try autoreleasepool {
            // The front-end's minimum length is 3200 samples; pad only a short
            // final tail, while the controller retains original timing/counts.
            let n = max(3200, samples.count)
            let waveform = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
            let wave = waveform.dataPointer.assumingMemoryBound(to: Float.self)
            wave.initialize(repeating: 0, count: n)
            for i in samples.indices { wave[i] = samples[i] * 32768 }
            let front = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform]))
            guard let features = front.featureValue(for: "features")?.multiArrayValue,
                  features.shape.count == 3, features.shape[2].intValue == 560, features.dataType == .float32 else {
                throw LectureError.message("SenseVoice 前處理輸出不相符。")
            }
            let frames = features.shape[1].intValue
            guard frames > 0, let bucket = buckets.first(where: { $0 >= frames }) else {
                throw LectureError.message("SenseVoice 音訊片段過長；原始錄音已保留。")
            }
            let speech = try MLMultiArray(shape: [1, NSNumber(value: bucket), 560], dataType: .float32)
            let padded = speech.dataPointer.assumingMemoryBound(to: Float.self)
            padded.initialize(repeating: 0, count: bucket * 560)
            let featureData = features.dataPointer.assumingMemoryBound(to: Float.self)
            let rowStride = features.strides[1].intValue, columnStride = features.strides[2].intValue
            for row in 0..<frames {
                for column in 0..<560 { padded[row * 560 + column] = featureData[row * rowStride + column * columnStride] }
            }
            func scalar(_ value: Int32) throws -> MLMultiArray {
                let array = try MLMultiArray(shape: [1], dataType: .int32)
                array[0] = NSNumber(value: value); return array
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["speech": speech,
                "speech_lengths": try scalar(Int32(frames)), "language": try scalar(selectedLanguage), "textnorm": try scalar(14)])
            let output = try encoder.prediction(from: input)
            try Task.checkCancellation()
            guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue,
                  logits.shape.count == 3, logits.shape[2].intValue == vocabulary.count,
                  logits.dataType == .float32 || logits.dataType == .float16 else {
                throw LectureError.message("SenseVoice 辨識輸出不相符。")
            }
            let valid = min(frames + 4, logits.shape[1].intValue)
            let stride = logits.strides[1].intValue, column = logits.strides[2].intValue
            var tokens: [Int] = []; var previous = -1
            for frame in 0..<valid {
                var best = 0; var maximum = -Float.infinity
                for token in vocabulary.indices {
                    let position = frame * stride + token * column
                    let value: Float
                    if logits.dataType == .float32 { value = logits.dataPointer.assumingMemoryBound(to: Float.self)[position] }
                    else { value = Float(logits.dataPointer.assumingMemoryBound(to: Float16.self)[position]) }
                    guard value.isFinite else {
                        throw LectureError.message("SenseVoice Core ML 在這台裝置產生無效數值。錄音已保留，請先改用 Apple 或 WhisperKit；不會把錯誤結果定稿。")
                    }
                    if value > maximum { maximum = value; best = token }
                }
                if best != 0 && best != previous { tokens.append(best) }
                previous = best
            }
            let text = SenseVoiceText.decode(tokens, vocabulary: vocabulary)
            return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        }
    }

    private func languageIndex(_ language: String) -> Int32 {
        switch SenseVoiceWindow.modelLanguage(language) { case "zh": return 3; case "en": return 4; default: return 0 }
    }
    private static func matches(_ url: URL, size: Int, digest: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue == size,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        do {
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
        } catch { return false }
    }
}
