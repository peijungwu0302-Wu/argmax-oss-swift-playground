import Foundation

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
