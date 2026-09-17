import Foundation
import AVFoundation

// Audio tap and mutable data are serialized by lock. No growing RAM audio buffer.
final class PCMRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var writer: FileHandle?
    private var masterAudioFile: AVAudioFile?
    private var count = 0
    private var level: Float = 0
    private var failure: String?
    private var accepting = false
    private var dynamicsProcessor = SpeechDynamicsProcessor(sampleRate: 16000)

    /// Optional real-time callback delivering pristine 16 kHz mono Float32 audio to ASR router
    var onASRAudio: (@Sendable ([Float]) -> Void)?

    private var masterCreationError: String?
    private var masterWriteFailed: Bool = false
    private var masterError: String?
    private var masterFramesWritten: Int = 0
    private var masterSampleRate: Double = 0.0

    struct Snapshot: Sendable {
        var samples: Int
        var level: Float
        var error: String?
        var dynamics: AudioDynamicsDiagnostics
        var isMasterActive: Bool
        var masterWriteFailed: Bool
        var masterError: String?
        var masterFramesWritten: Int
        var masterSampleRate: Double

        init(
            samples: Int,
            level: Float,
            error: String? = nil,
            dynamics: AudioDynamicsDiagnostics = AudioDynamicsDiagnostics(),
            isMasterActive: Bool = false,
            masterWriteFailed: Bool = false,
            masterError: String? = nil,
            masterFramesWritten: Int = 0,
            masterSampleRate: Double = 0.0
        ) {
            self.samples = samples
            self.level = level
            self.error = error
            self.dynamics = dynamics
            self.isMasterActive = isMasterActive
            self.masterWriteFailed = masterWriteFailed
            self.masterError = masterError
            self.masterFramesWritten = masterFramesWritten
            self.masterSampleRate = masterSampleRate
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            samples: count,
            level: level,
            error: failure,
            dynamics: dynamicsProcessor.currentDiagnostics(),
            isMasterActive: masterAudioFile != nil && !masterWriteFailed,
            masterWriteFailed: masterWriteFailed,
            masterError: masterError ?? masterCreationError,
            masterFramesWritten: masterFramesWritten,
            masterSampleRate: masterSampleRate
        )
    }

    static func masterURL(for intermediateURL: URL) -> URL {
        intermediateURL.deletingPathExtension().appendingPathExtension("master.caf")
    }

    @MainActor
    func start(at url: URL, allowsPlayback: Bool = false) throws {
        // Centralized AudioSession policy
        try AudioSessionCoordinator.shared.activateMicrophoneCapture(allowsPlayback: allowsPlayback)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw LectureError.message("無法啟動麥克風，請確認輸入裝置已連接。")
        }
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw LectureError.message("無法建立新的錄音檔。請確認裝置剩餘空間。")
        }
        let file = try FileHandle(forWritingTo: url)

        // Setup listener master file at native sample rate
        let master = Self.masterURL(for: url)
        if FileManager.default.fileExists(atPath: master.path) {
            try? FileManager.default.removeItem(at: master)
        }
        var masterFile: AVAudioFile? = nil
        var masterErr: String? = nil
        if let masterFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) {
            do {
                masterFile = try AVAudioFile(forWriting: master, settings: masterFormat.settings)
            } catch {
                masterErr = "建立主錄音檔失敗：\(error.localizedDescription)"
            }
        } else {
            masterErr = "無法建立主錄音格式（取樣率：\(format.sampleRate)）"
        }

        lock.lock()
        dynamicsProcessor = SpeechDynamicsProcessor(sampleRate: format.sampleRate)
        writer = file
        masterAudioFile = masterFile
        masterCreationError = masterErr
        masterWriteFailed = masterFile == nil && masterErr != nil
        masterError = masterErr
        masterFramesWritten = 0
        masterSampleRate = format.sampleRate
        count = 0
        level = 0
        failure = nil
        accepting = true
        lock.unlock()
        self.engine = engine

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.accepting, self.failure == nil, let writer = self.writer else { return }

            // 1. Branch B (Recording Master): Process native mic audio through SpeechDynamicsProcessor
            var masterSamples: [Float] = []
            if let channel0 = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let nativeLength = Int(buffer.frameLength)
                let nativeSamples = Array(UnsafeBufferPointer(start: channel0, count: nativeLength))
                masterSamples = self.dynamicsProcessor.process(nativeSamples)

                if let masterAudioFile = self.masterAudioFile,
                   let masterBuffer = AVAudioPCMBuffer(pcmFormat: masterAudioFile.processingFormat, frameCapacity: buffer.frameCapacity),
                   let dst = masterBuffer.floatChannelData?[0] {
                    masterBuffer.frameLength = buffer.frameLength
                    masterSamples.withUnsafeBufferPointer {
                        dst.update(from: $0.baseAddress!, count: nativeLength)
                    }
                    do {
                        try masterAudioFile.write(from: masterBuffer)
                        self.masterFramesWritten += Int(buffer.frameLength)
                    } catch {
                        self.masterWriteFailed = true
                        self.masterError = "主錄音寫入中斷：\(error.localizedDescription)"
                        self.masterAudioFile = nil
                    }
                }
            }

            // 2. Branch A (ASR Branch): Resample native buffer to pristine 16 kHz mono Float32
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / format.sampleRate)) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                self.failure = "音訊緩衝區配置失敗。"; return
            }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true; inputStatus.pointee = .haveData; return buffer
            }
            guard status != .error, error == nil else {
                self.failure = error?.localizedDescription ?? "音訊取樣轉換失敗。"; return
            }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
            let length = Int(output.frameLength)
            let asrSamples = Array(UnsafeBufferPointer(start: channel, count: length))

            // 2a. Deliver pristine uncompressed PCM to ASR branch (RAW, NO DSP)
            self.onASRAudio?(asrSamples)

            // 2b. Write raw 16 kHz PCM to crash-recoverable intermediate file (RAW, NO DSP)
            do {
                try writer.write(contentsOf: AudioStorage.encodePCM16(asrSamples))
                self.count += length
                // Compute level for UI
                let levelSamples = masterSamples.isEmpty ? asrSamples : masterSamples
                let power = levelSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, levelSamples.count))
                self.level = min(1, max(0, (20 * log10(max(sqrt(power), 0.00001)) + 60) / 60))
            } catch {
                self.failure = "錄音無法寫入磁碟：\(error.localizedDescription)"
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
    }

    @MainActor
    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        lock.lock()
        accepting = false
        do { try writer?.synchronize(); try writer?.close() }
        catch { failure = "錄音儲存失敗：\(error.localizedDescription)" }
        writer = nil
        masterAudioFile = nil
        // Preserve masterCreationError, masterWriteFailed, masterError, masterFramesWritten, and masterSampleRate!
        // Do NOT clear them here so controller / finalizer can inspect them!
        lock.unlock()

        AudioSessionCoordinator.shared.deactivateMicrophoneCapture()
    }

    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        try StoredAudio.read(url, from: start, count: count)
    }

    static func archive(_ source: URL, samples: Int, bitRate: Int, masterWriteFailed: Bool = false) throws -> URL {
        let master = masterURL(for: source)
        var sourceToArchive = source
        let expectedDuration = Double(samples) / 16000.0

        if !masterWriteFailed && FileManager.default.fileExists(atPath: master.path) {
            if let masterFile = try? AVAudioFile(forReading: master) {
                let masterDuration = Double(masterFile.length) / masterFile.fileFormat.sampleRate
                let tolerance = max(0.5, expectedDuration * 0.05)
                if abs(masterDuration - expectedDuration) <= tolerance {
                    sourceToArchive = master
                } else {
                    print("PCMRecorder.archive: master duration mismatch (\(masterDuration)s vs expected \(expectedDuration)s); falling back to recovery PCM.")
                }
            }
        }
        return try StoredAudio.archive(sourceToArchive, samples: samples, bitRate: bitRate)
    }

    static func archive(source: URL, samples: Int, quality: RecordingQuality, masterWriteFailed: Bool = false) throws -> URL {
        let master = masterURL(for: source)
        var sourceToArchive = source
        let expectedDuration = Double(samples) / 16000.0

        if !masterWriteFailed && FileManager.default.fileExists(atPath: master.path) {
            if let masterFile = try? AVAudioFile(forReading: master) {
                let masterDuration = Double(masterFile.length) / masterFile.fileFormat.sampleRate
                let tolerance = max(0.5, expectedDuration * 0.05)
                if abs(masterDuration - expectedDuration) <= tolerance {
                    sourceToArchive = master
                } else {
                    print("PCMRecorder.archive: master duration mismatch (\(masterDuration)s vs expected \(expectedDuration)s); falling back to recovery PCM.")
                }
            }
        }
        return try StoredAudio.archive(source: sourceToArchive, samples: samples, quality: quality)
    }
}
