import Foundation
import AVFoundation

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let count = 3 * 16000 + 173
let angularFrequency: Double = 2.0 * Double.pi * 440.0 / 16000.0
let samples: [Float] = (0..<count).map { Float(0.2 * sin(Double($0) * angularFrequency)) }
let source = folder.appendingPathComponent("test.pcm16")
try AudioStorage.encodePCM16(samples).write(to: source)
for rate in [32000, 64000] {
    print("Checking AAC bitrate \(rate)")
    let archive = try StoredAudio.archive(source, samples: count, bitRate: rate)
    let values = try StoredAudio.read(archive, from: 0, count: count)
    var squaredError: Float = 0
    for index in 0..<count {
        let difference = values[index] - samples[index]
        squaredError += difference * difference
    }
    precondition(squaredError / Float(count) < 0.002, "AAC signal/timing mismatch")
    let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as! NSNumber
    precondition(size.intValue < count * 2, "AAC failed to reduce recording size")
    print("PASS: AAC \(rate), \(count) source frames including tail, \(size) bytes")
}

let wav = try StoredAudio.playable(source, samples: count)
let copied = folder.appendingPathComponent("imported.pcm16")
let importedCount = try StoredAudio.importAudio(wav, to: copied)
precondition(importedCount == count)
let importedValues = try StoredAudio.read(copied, from: 0, count: count)
precondition(zip(importedValues, samples).allSatisfy { abs($0 - $1) < 0.00004 })
let stereo = folder.appendingPathComponent("stereo.wav")
let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
do {
    let file = try AVAudioFile(forWriting: stereo, settings: stereoFormat.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 96000)!
    buffer.frameLength = 96000
    for i in 0..<96000 {
        let tone = Float(sin(Double(i) * 2 * .pi * 440 / 48000))
        buffer.floatChannelData![0][i] = tone * 0.1
        buffer.floatChannelData![1][i] = tone * 0.3
    }
    try file.write(from: buffer)
}
let stereoCopy = folder.appendingPathComponent("stereo.pcm16")
let convertedCount = try StoredAudio.importAudio(stereo, to: stereoCopy)
precondition(abs(convertedCount - 32000) <= 1, "Imported duration must survive resampling")
let mono = try StoredAudio.read(stereoCopy, from: 8000, count: 16000)
precondition(mono.map { abs($0) }.max()! > 0.1, "Downmix cannot erase both channels")
precondition(FileManager.default.fileExists(atPath: stereo.path), "Import cannot remove the user's original")
try? FileManager.default.removeItem(at: wav)
print("PASS: legacy PCM WAV playback/share, file import, stereo downmix, resampling and duration")
