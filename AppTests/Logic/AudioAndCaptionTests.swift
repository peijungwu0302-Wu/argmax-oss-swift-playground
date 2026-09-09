import XCTest
import AVFoundation
@testable import LectureTranscriber

final class AudioAndCaptionTests: XCTestCase {
    func testPCM16AndAACRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("test.pcm16")
        let count = 3 * 16000 + 173 // Deliberately not a whole AAC frame.
        let angularFrequency: Double = 2.0 * Double.pi * 440.0 / 16000.0
        let samples: [Float] = (0..<count).map { index in
            Float(0.2 * sin(Double(index) * angularFrequency))
        }
        try AudioStorage.encodePCM16(samples).write(to: source)
        let middle = try PCMRecorder.read(source, from: 8000, count: 4000)
        XCTAssertEqual(middle.count, 4000)
        XCTAssertLessThan(abs(middle[133] - samples[8133]), 0.00004)
        XCTAssertThrowsError(try PCMRecorder.read(source, from: count - 1, count: 2))
        for rate in [32000, 64000] {
            let archive = try PCMRecorder.archive(source, samples: count, bitRate: rate)
            let decoded = try PCMRecorder.read(archive, from: 0, count: count)
            XCTAssertEqual(decoded.count, count, "AAC must retain the original final samples")
            var squaredError: Float = 0
            for index in 0..<count {
                let difference: Float = decoded[index] - samples[index]
                squaredError += difference * difference
            }
            let error: Float = squaredError / Float(count)
            XCTAssertLessThan(error, 0.002, "AAC decoding must retain the signal and timing")
            let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as! NSNumber
            XCTAssertLessThan(size.intValue, count * 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The encoder cannot delete the source before metadata is committed")
        }
        XCTAssertThrowsError(try PCMRecorder.archive(source, samples: count + 16000, bitRate: 32000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testCaptionTranslationMustMatchCurrentSource() {
        let controller = LectureController()
        let first = TranscriptLine(start: 0, end: 2, text: "Hello")
        let latest = TranscriptLine(start: 3, end: 5, text: "Goodbye")
        controller.session = LectureSession(title: "test", model: "test", language: "en", lines: [first, latest],
            translations: [TranslatedLine(id: first.id, source: "Hello", text: "你好")])
        XCTAssertEqual(controller.translationCaption, "", "Do not pair the latest source with an older translation")
        controller.liveDraftStart = 6; controller.liveDraft = "Hello"
        controller.translationDraftKey = controller.draftTranslationKey
        controller.translatedDraft = "你好"
        XCTAssertEqual(controller.validTranslatedDraft, "你好")
        controller.liveDraftStart = 10
        XCTAssertEqual(controller.validTranslatedDraft, "", "Repeated text at a new time needs its own translation")
        controller.translationDraftKey = controller.draftTranslationKey
        controller.restartTranslation()
        XCTAssertEqual(controller.validTranslatedDraft, "")
    }
}
