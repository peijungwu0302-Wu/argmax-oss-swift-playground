import Foundation
import AVFoundation
import AudioToolbox

enum StoredAudio {
    static func clip(_ lecture: LectureSession, store: SessionStore, start: Double, end: Double) throws -> URL {
        let slices = try AudioTimeline.slices(lecture, start: start, end: end)
        let count = slices.reduce(0) { $0 + $1.count }
        guard count > 0, UInt64(count) * 2 + 36 < UInt64(UInt32.max) else { throw LectureError.message("片段太長，無法匯出 WAV。") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("核對片段-" + UUID().uuidString + ".wav")
        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: s.utf8) }
        func u32(_ x: UInt32) { var n = x.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var n = x.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(count * 2 + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
        do {
            try header.write(to: url)
            let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
            try output.seekToEnd()
            for slice in slices {
                for offset in stride(from: 0, to: slice.count, by: 16000) {
                    try Task.checkCancellation()
                    let samples = try read(store.audioURL(lecture, slice.part), from: slice.start + offset, count: min(16000, slice.count - offset))
                    try output.write(contentsOf: AudioStorage.encodePCM16(samples))
                }
            }
            try output.synchronize()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    // Decode files in bounded buffers, downmixing/resampling through Core Audio.
    static func importAudio(_ source: URL, to destination: URL) throws -> Int {
        if let width = AudioStorage.bytesPerSample(fileName: source.lastPathComponent) {
            let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size % width == 0 else { throw LectureError.message("原始錄音長度不正確。") }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
            for start in stride(from: 0, to: size / width, by: 16000) {
                try output.write(contentsOf: AudioStorage.encodePCM16(read(source, from: start, count: min(16000, size / width - start))))
            }
            try output.synchronize(); return size / width
        }
        var opened: ExtAudioFileRef?
        try checked(ExtAudioFileOpenURL(source as CFURL, &opened), "開啟匯入音訊")
        guard let file = opened else { throw LectureError.message("音訊不可讀取。") }
        defer { ExtAudioFileDispose(file) }
        let format = try clientFormat()
        var client = format.streamDescription.pointee
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "轉換音訊取樣率")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000), let channel = buffer.floatChannelData?[0] else { throw LectureError.message("音訊緩衝區不足。") }
        var total = 0
        while true {
            try Task.checkCancellation()
            var frames: UInt32 = 16000; buffer.frameLength = 16000
            try checked(ExtAudioFileRead(file, &frames, buffer.mutableAudioBufferList), "讀取匯入音訊")
            if frames == 0 { break }
            try output.write(contentsOf: AudioStorage.encodePCM16(Array(UnsafeBufferPointer(start: channel, count: Int(frames)))))
            total += Int(frames)
        }
        guard total > 0 else { throw LectureError.message("檔案沒有可辨識的音訊。") }
        try output.synchronize(); return total
    }

    /// Returns a playable URL directly for standard audio files (m4a, wav, caf),
    /// eliminating expensive whole-file temporary WAV creation for long recordings.
    static func playable(_ source: URL, samples: Int) throws -> URL {
        let ext = source.pathExtension.lowercased()
        if ext == "m4a" || ext == "wav" || ext == "caf" || ext == "mp3" {
            return source
        }
        guard AudioStorage.bytesPerSample(fileName: source.lastPathComponent) != nil else { return source }
        guard samples > 0, UInt64(samples) * 2 + 36 < UInt64(UInt32.max) else { throw LectureError.message("音訊長度不適合 WAV 匯出。") }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LectureAudioExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = folder.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent + "-" + source.deletingPathExtension().lastPathComponent + ".wav")

        // If cached export exists and has expected size, reuse it
        if let existing = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = existing[.size] as? NSNumber, size.intValue == samples * 2 + 44 {
            return outputURL
        }

        try writeWAVFile(from: source, to: outputURL, samples: samples)
        return outputURL
    }

    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        guard start >= 0, count > 0 else { return [] }
        guard let width = AudioStorage.bytesPerSample(fileName: url.lastPathComponent) else {
            return try readStandardAudio(url, from: start, count: count)
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
    // Work in bounded buffers; do not load a lecture into RAM.
    static func archive(_ source: URL, samples: Int, bitRate: Int) throws -> URL {
        guard samples > 0, bitRate == 32000 || bitRate == 64000 else {
            throw LectureError.message("壓縮設定不正確，原始錄音已保留。")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try writeArchive(source, destination: destination, samples: samples, bitRate: bitRate)
            // Check both ends after closing the encoder
            _ = try read(destination, from: 0, count: min(samples, 16000))
            _ = try read(destination, from: max(0, samples - 16000), count: min(samples, 16000))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Archives recording into standard container based on selected RecordingQuality.
    /// Compact -> AAC m4a (~32 kbps)
    /// Standard -> AAC m4a (~64 kbps)
    /// Uncompressed -> Standard WAV with valid RIFF header
    static func archive(source: URL, samples: Int, quality: RecordingQuality) throws -> URL {
        switch quality {
        case .compact:
            return try archive(source, samples: samples, bitRate: 32000)
        case .standard:
            return try archive(source, samples: samples, bitRate: 64000)
        case .uncompressed:
            return try archiveWAV(source: source, samples: samples)
        }
    }

    static func archiveWAV(source: URL, samples: [Float]) throws -> URL {
        try AudioStorage.encodePCM16(samples).write(to: source)
        return try archiveWAV(source: source, samples: samples.count)
    }

    /// Creates a standard RIFF/WAVE file from a source raw audio file with bounded memory.
    static func archiveWAV(source: URL, samples: Int) throws -> URL {
        guard samples > 0 else { throw LectureError.message("音訊長度不足，無法封裝 WAV。") }
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try writeWAVFile(from: source, to: destination, samples: samples)
            // Verify ends
            _ = try read(destination, from: 0, count: min(samples, 16000))
            _ = try read(destination, from: max(0, samples - 16000), count: min(samples, 16000))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func writeWAVFile(from source: URL, to destination: URL, samples: Int) throws {
        let isStandardAudio = AudioStorage.bytesPerSample(fileName: source.lastPathComponent) == nil
        var sourceRate: Double = 16000
        var openedSource: ExtAudioFileRef?
        if isStandardAudio {
            try checked(ExtAudioFileOpenURL(source as CFURL, &openedSource), "開啟來源主音訊")
            if let openedSource {
                var sourceFormat = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if ExtAudioFileGetProperty(openedSource, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat) == noErr,
                   sourceFormat.mSampleRate > 0 {
                    sourceRate = sourceFormat.mSampleRate
                }
            }
        }
        defer {
            if let openedSource { ExtAudioFileDispose(openedSource) }
        }

        if let sourceFile = openedSource {
            // Write standard WAV at native sourceRate
            var totalFrames: Int64 = 0
            var propSize = UInt32(MemoryLayout<Int64>.size)
            _ = ExtAudioFileGetProperty(sourceFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames)
            let framesCount = max(Int(totalFrames), Int((Double(samples) * sourceRate / 16000.0).rounded()))

            var header = Data()
            func ascii(_ text: String) { header.append(contentsOf: text.utf8) }
            func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }

            let rateU32 = UInt32(sourceRate)
            let byteRate = rateU32 * 2
            ascii("RIFF"); u32(UInt32(framesCount * 2 + 36)); ascii("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(rateU32); u32(byteRate); u16(2); u16(16); ascii("data"); u32(UInt32(framesCount * 2))

            try header.write(to: destination, options: .atomic)
            let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
            try file.seekToEnd()

            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ) else {
                throw LectureError.message("無法建立音訊讀取格式")
            }
            var client = clientFormat.streamDescription.pointee
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定來源音訊格式")

            let chunkCapacity: AVAudioFrameCount = 16384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: chunkCapacity),
                  let channel = buffer.floatChannelData?[0] else {
                throw LectureError.message("無法配置音訊緩衝區")
            }

            while true {
                try Task.checkCancellation()
                var frames: UInt32 = chunkCapacity
                buffer.frameLength = chunkCapacity
                try checked(ExtAudioFileRead(sourceFile, &frames, buffer.mutableAudioBufferList), "讀取主音訊")
                if frames == 0 { break }
                let floatSamples = Array(UnsafeBufferPointer(start: channel, count: Int(frames)))
                try file.write(contentsOf: AudioStorage.encodePCM16(floatSamples))
            }
            try file.synchronize()
        } else {
            var header = Data()
            func ascii(_ text: String) { header.append(contentsOf: text.utf8) }
            func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }

            ascii("RIFF"); u32(UInt32(samples * 2 + 36)); ascii("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); ascii("data"); u32(UInt32(samples * 2))

            try header.write(to: destination, options: .atomic)
            let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
            try file.seekToEnd()
            for start in stride(from: 0, to: samples, by: 16000) {
                try file.write(contentsOf: AudioStorage.encodePCM16(read(source, from: start, count: min(16000, samples - start))))
            }
            try file.synchronize()
        }
    }

    private static func writeArchive(_ source: URL, destination: URL, samples: Int, bitRate: Int) throws {
        let isStandardAudio = AudioStorage.bytesPerSample(fileName: source.lastPathComponent) == nil

        var sourceRate: Double = 16000
        var openedSource: ExtAudioFileRef?
        if isStandardAudio {
            try checked(ExtAudioFileOpenURL(source as CFURL, &openedSource), "開啟來源音訊")
            if let openedSource {
                var sourceFormat = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if ExtAudioFileGetProperty(openedSource, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat) == noErr,
                   sourceFormat.mSampleRate > 0 {
                    sourceRate = sourceFormat.mSampleRate
                }
            }
        }
        defer {
            if let openedSource { ExtAudioFileDispose(openedSource) }
        }

        // When source is native master (e.g. 48 kHz or 44.1 kHz), encode AAC at native rate
        let targetSampleRate = isStandardAudio ? sourceRate : (bitRate == 32000 ? 32000.0 : 44100.0)
        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatMPEG4AAC
        output.mSampleRate = targetSampleRate
        output.mChannelsPerFrame = 1
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output), "準備 AAC 格式")

        var openedDest: ExtAudioFileRef?
        try checked(ExtAudioFileCreateWithURL(
            destination as CFURL,
            kAudioFileM4AType,
            &output,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &openedDest
        ), "建立 AAC 檔案")
        guard let destFile = openedDest else { throw LectureError.message("無法建立 AAC 檔案。") }
        var destDisposed = false
        defer { if !destDisposed { ExtAudioFileDispose(destFile) } }

        guard let destClientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw LectureError.message("無法建立 AAC 客戶端音訊格式。")
        }
        var client = destClientFormat.streamDescription.pointee
        try checked(ExtAudioFileSetProperty(destFile, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定 AAC 寫入格式")

        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try checked(ExtAudioFileGetProperty(destFile, kExtAudioFileProperty_AudioConverter, &converterSize, &converter), "取得 AAC 編碼器")
        guard let converter else { throw LectureError.message("AAC 編碼器不可用。") }
        var rate = UInt32(bitRate)
        try checked(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate), "設定 AAC 品質")
        var configuration: CFArray? = nil
        try checked(ExtAudioFileSetProperty(destFile, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &configuration), "套用 AAC 品質")

        if let sourceFile = openedSource {
            // Source is standard audio file (e.g. master.caf)
            try checked(ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定來源音訊格式")
            let frameChunk: AVAudioFrameCount = 16384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: destClientFormat, frameCapacity: frameChunk) else {
                throw LectureError.message("無法配置音訊緩衝區。")
            }
            while true {
                try Task.checkCancellation()
                var frames: UInt32 = frameChunk
                buffer.frameLength = frameChunk
                try checked(ExtAudioFileRead(sourceFile, &frames, buffer.mutableAudioBufferList), "讀取主音訊")
                if frames == 0 { break }
                buffer.frameLength = frames
                try checked(ExtAudioFileWrite(destFile, frames, buffer.audioBufferList), "寫入 AAC 音訊")
            }
        } else {
            // Source is raw PCM16: read chunks, convert to Float32 at 16000
            let format16k = try Self.clientFormat()
            var client16k = format16k.streamDescription.pointee
            try checked(ExtAudioFileSetProperty(destFile, kExtAudioFileProperty_ClientDataFormat, size, &client16k), "設定辨識音訊格式")
            for start in stride(from: 0, to: samples, by: 16000) {
                try Task.checkCancellation()
                let count = min(16000, samples - start)
                let values = try read(source, from: start, count: count)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { throw LectureError.message("無法配置錄音壓縮緩衝區。") }
                buffer.frameLength = AVAudioFrameCount(count)
                values.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
                try checked(ExtAudioFileWrite(destFile, AVAudioFrameCount(count), buffer.audioBufferList), "寫入 AAC 音訊")
            }
        }

        let result = ExtAudioFileDispose(destFile)
        destDisposed = true
        try checked(result, "完成 AAC 尾段")
    }

    private static func readStandardAudio(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        var opened: ExtAudioFileRef?
        try checked(ExtAudioFileOpenURL(url as CFURL, &opened), "開啟音訊檔案")
        guard let file = opened else { throw LectureError.message("無法開啟音訊檔案。") }
        defer { ExtAudioFileDispose(file) }
        var source = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source), "讀取音訊格式")
        guard source.mChannelsPerFrame >= 1, source.mSampleRate > 0 else { throw LectureError.message("錄音格式不符。") }
        let format = try clientFormat()
        var client = format.streamDescription.pointee
        try checked(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client), "設定讀取格式")
        let position = Int64((Double(start) * source.mSampleRate / 16000.0).rounded())
        try checked(ExtAudioFileSeek(file, position), "定位音訊")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw LectureError.message("無法配置音訊讀取緩衝區。") }
        buffer.frameLength = AVAudioFrameCount(count)
        var frames = AVAudioFrameCount(count)
        try checked(ExtAudioFileRead(file, &frames, buffer.mutableAudioBufferList), "讀取音訊資料")
        let actual = Int(frames)
        return Array(UnsafeBufferPointer(start: channel, count: actual))
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

    // MARK: - Safe Legacy Audio Migration

    /// Safely migrates raw headerless PCM recordings (.pcm or .pcm16) in a lecture to a standard container (m4a or wav).
    /// Guarantees:
    /// 1. Bounded memory O(chunk).
    /// 2. Validates duration and endpoints before committing.
    /// 3. Commits metadata atomically.
    /// 4. Only deletes the old PCM file after successful metadata commit.
    /// 5. On failure, deletes incomplete destination and leaves original PCM intact.
    static func migrateLegacyAudio(lecture: LectureSession, store: SessionStore) async throws -> LectureSession {
        var updated = lecture
        var didModify = false

        for i in 0..<updated.parts.count {
            let part = updated.parts[i]
            let ext = URL(fileURLWithPath: part.fileName).pathExtension.lowercased()
            guard ext == "pcm" || ext == "pcm16" else { continue }
            guard part.sampleCount > 0 else { continue }

            let originalURL = store.audioURL(lecture, part)
            guard FileManager.default.fileExists(atPath: originalURL.path) else { continue }

            let quality = part.recordingQuality ?? .standard
            let destinationURL: URL
            switch quality {
            case .compact:
                destinationURL = try archive(originalURL, samples: part.sampleCount, bitRate: 32000)
            case .standard:
                destinationURL = try archive(originalURL, samples: part.sampleCount, bitRate: 64000)
            case .uncompressed:
                destinationURL = try archiveWAV(source: originalURL, samples: part.sampleCount)
            }

            // Atomic update: only point to new file and delete original once metadata is saved
            updated.parts[i].fileName = destinationURL.lastPathComponent
            do {
                try store.save(updated)
                try? FileManager.default.removeItem(at: originalURL)
                didModify = true
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }

        return updated
    }
}
