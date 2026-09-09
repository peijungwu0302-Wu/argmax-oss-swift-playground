import Foundation
import AVFoundation

// Audio tap and mutable data are serialized by lock. No growing RAM audio buffer.
final class PCMRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var writer: FileHandle?
    private var count = 0
    private var level: Float = 0
    private var failure: String?
    private var accepting = false
    struct Snapshot { var samples: Int; var level: Float; var error: String? }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(samples: count, level: level, error: failure)
    }
    func start(at url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
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
        lock.lock()
        writer = file; count = 0; level = 0; failure = nil; accepting = true
        lock.unlock()
        self.engine = engine
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.accepting, self.failure == nil, let writer = self.writer else { return }
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
            do {
                try writer.write(contentsOf: AudioStorage.encodePCM16(Array(UnsafeBufferPointer(start: channel, count: length))))
                self.count += length
                let power = UnsafeBufferPointer(start: channel, count: length).reduce(Float(0)) { $0 + $1 * $1 } / Float(length)
                self.level = min(1, max(0, (20 * log10(max(sqrt(power), 0.00001)) + 60) / 60))
            } catch { self.failure = "錄音無法寫入磁碟：\(error.localizedDescription)" }
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
    }
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
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        try StoredAudio.read(url, from: start, count: count)
    }
    static func archive(_ source: URL, samples: Int, bitRate: Int) throws -> URL {
        try StoredAudio.archive(source, samples: samples, bitRate: bitRate)
    }
}
