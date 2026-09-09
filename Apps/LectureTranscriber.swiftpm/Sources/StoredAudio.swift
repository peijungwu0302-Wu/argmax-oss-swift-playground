import Foundation
import AVFoundation
import AudioToolbox

enum StoredAudio {
    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        guard start >= 0, count > 0 else { return [] }
        guard let width = AudioStorage.bytesPerSample(fileName: url.lastPathComponent) else {
            return try readCompressed(url, from: start, count: count)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(start) * UInt64(width))
        var data = Data()
        while data.count < count * width {
            let portion = try file.read(upToCount: count * width - data.count) ?? Data()
            guard !portion.isEmpty else { throw LectureError.message("錄音檔長度不足，已保留未完成的位置，請稍後重試。") }
            data.append(portion)
        }
        if width == 2 { return AudioStorage.decodePCM16(data) }
        var samples = [Float](repeating: 0, count: data.count / 4)
        _ = samples.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
        return samples
    }

    // Archive only after capture closes and all recognition has consumed the PCM.
    // Work in bounded buffers; do not load a lecture into RAM. The caller commits
    // the verified new filename atomically before removing the original file.
    static func archive(_ source: URL, samples: Int, bitRate: Int) throws -> URL {
        guard samples > 0, bitRate == 32000 || bitRate == 64000 else {
            throw LectureError.message("壓縮設定不正確，原始錄音已保留。")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try writeArchive(source, destination: destination, samples: samples, bitRate: bitRate)
            // Check both ends after closing the encoder, including its delayed tail.
            _ = try read(destination, from: 0, count: min(samples, 16000))
            _ = try read(destination, from: max(0, samples - 16000), count: min(samples, 16000))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    private static func writeArchive(_ source: URL, destination: URL, samples: Int, bitRate: Int) throws {
        // AAC's supported rate/bitrate pairs differ from the 16 kHz ASR format.
        // Use 32 kHz for the archive; ExtAudioFile converts from the original
        // 16 kHz client format, including converter priming and the final tail.
        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatMPEG4AAC; output.mSampleRate = 32000; output.mChannelsPerFrame = 1
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output), "準備 AAC 格式")
        var opened: ExtAudioFileRef?
        try checked(ExtAudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType, &output, nil,
            AudioFileFlags.eraseFile.rawValue, &opened), "建立 AAC 檔案")
        guard let file = opened else { throw LectureError.message("無法建立 AAC 檔案。") }
        var disposed = false
        defer { if !disposed { ExtAudioFileDispose(file) } }
        let format = try clientFormat()
        var client = format.streamDescription.pointee
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定辨識音訊格式")
        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try checked(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &converterSize, &converter), "取得 AAC 編碼器")
        guard let converter else { throw LectureError.message("AAC 編碼器不可用。") }
        var rate = UInt32(bitRate)
        try checked(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate), "設定 AAC 品質")
        var configuration: CFArray? = nil
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
            UInt32(MemoryLayout<CFArray?>.size), &configuration), "套用 AAC 品質")
        for start in stride(from: 0, to: samples, by: 16000) {
            let count = min(16000, samples - start)
            let values = try read(source, from: start, count: count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw LectureError.message("無法配置錄音壓縮緩衝區。") }
            buffer.frameLength = AVAudioFrameCount(count)
            values.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
            try checked(ExtAudioFileWrite(file, AVAudioFrameCount(count), buffer.audioBufferList), "写入 AAC 音訊")
        }
        let result = ExtAudioFileDispose(file); disposed = true
        try checked(result, "完成 AAC 尾段")
    }
    private static func readCompressed(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        var opened: ExtAudioFileRef?
        try checked(ExtAudioFileOpenURL(url as CFURL, &opened), "開啟 AAC 錄音")
        guard let file = opened else { throw LectureError.message("無法開啟 AAC 錄音。") }
        defer { ExtAudioFileDispose(file) }
        var source = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source), "讀取 AAC 格式")
        guard source.mChannelsPerFrame == 1, source.mSampleRate > 0 else { throw LectureError.message("錄音格式不符。") }
        let format = try clientFormat()
        var client = format.streamDescription.pointee
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定 AAC 讀取格式")
        let position = Int64((Double(start) * source.mSampleRate / 16000).rounded())
        try checked(ExtAudioFileSeek(file, position), "定位 AAC 音訊")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw LectureError.message("無法配置 AAC 讀取緩衝區。") }
        buffer.frameLength = AVAudioFrameCount(count)
        var frames = AVAudioFrameCount(count)
        try checked(ExtAudioFileRead(file, &frames, buffer.mutableAudioBufferList), "讀取 AAC 音訊")
        guard Int(frames) == count else { throw LectureError.message("壓縮錄音長度不足，原檔已保留。") }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
    private static func clientFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw LectureError.message("無法建立錄音格式。")
        }
        return format
    }
    private static func checked(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw LectureError.message("\(action)失敗（\(status)），原始錄音已保留。") }
    }
}
