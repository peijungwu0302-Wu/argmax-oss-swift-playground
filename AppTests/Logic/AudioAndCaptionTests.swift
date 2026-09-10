import XCTest
import AVFoundation
import CryptoKit
@testable import LectureTranscriber

final class AudioAndCaptionTests: XCTestCase {
    func testManualTimelineClipAcrossParts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SessionStore(root: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        var lecture = LectureSession(title: "核對原音", model: "test", language: "auto")
        lecture.parts = [.init(fileName: "a.pcm16", offset: 0, sampleCount: 32000), .init(fileName: "b.pcm16", offset: 2, sampleCount: 32000)]
        try store.save(lecture)
        let a = AudioStorage.encodePCM16([Float](repeating: 0.1, count: 32000))
        let b = AudioStorage.encodePCM16([Float](repeating: -0.1, count: 32000))
        try a.write(to: store.audioURL(lecture, lecture.parts[0])); try b.write(to: store.audioURL(lecture, lecture.parts[1]))
        let clip = try StoredAudio.clip(lecture, store: store, start: 1.5, end: 2.5)
        defer { try? FileManager.default.removeItem(at: clip) }
        let decoded = try StoredAudio.read(clip, from: 0, count: 16000)
        XCTAssertEqual(decoded[7999], 0.1, accuracy: 0.00004)
        XCTAssertEqual(decoded[8000], -0.1, accuracy: 0.00004)
        XCTAssertEqual(try AVAudioPlayer(contentsOf: clip).duration, 1, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(lecture, lecture.parts[0])), a)
    }

    @MainActor func testSideStoreUpdateIdentityAndURL() throws {
        let ipa = URL(string: AppUpdates.base + "LectureTranscriber-1.6.0-unsigned.ipa")!
        var update = LectureUpdate(bundleIdentifier: "com.peijungwu0302.lecturetranscriber", version: "1.6.0", build: 11,
                                   minimumOS: "16.0", downloadURL: ipa, notes: "test")
        try update.validate()
        XCTAssertTrue(update.newer(than: "1.5.0", build: 10))
        XCTAssertFalse(update.newer(than: "1.6.0", build: 11))
        let link = try XCTUnwrap(AppUpdates.sideStoreURL(action: "install", target: ipa))
        XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, ipa.absoluteString)
        update.bundleIdentifier = "other.app"
        XCTAssertThrowsError(try update.validate())
    }

    @MainActor func testReviewCannotOverwriteManualEdits() {
        let controller = LectureController()
        var line = TranscriptLine(start: 0, end: 1, text: "使用者修改")
        line.userEdited = true
        let lecture = LectureSession(title: "test", model: "test", language: "auto", lines: [line])
        controller.session = lecture
        controller.applyReview(line, replacements: [.init(start: 0, end: 1, text: "new")], sessionID: lecture.id)
        XCTAssertEqual(controller.session?.lines.first?.text, "使用者修改")
    }
    @MainActor
    func testUniversalInstallConfiguration() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.peijungwu0302.lecturetranscriber")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.6.0")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "11")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int], [1, 2])
        XCTAssertTrue(LectureController().supportsBackgroundAudio)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIRequiresFullScreen") as? Bool, false)
    }
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
            print("Checking AAC bitrate \(rate)")
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
    func testImportAudioCreatesRecoverableLecture() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcm16")
        let data = AudioStorage.encodePCM16([Float](repeating: 0.1, count: 32000))
        try data.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let controller = LectureController()
        controller.recognitionEngine = "sensevoice"
        controller.translationSource = "ja"
        await controller.importAudio(original)
        let lecture = try XCTUnwrap(controller.session)
        defer { controller.deleteLecture(lecture.id) }
        XCTAssertEqual(lecture.parts[0].sampleCount, 32000)
        XCTAssertTrue(lecture.hasPendingAudio)
        XCTAssertEqual(lecture.recognitionEngine, "sensevoice")
        XCTAssertEqual(lecture.translationSource, "ja")
        XCTAssertEqual(try Data(contentsOf: original), data)
        let file = try XCTUnwrap(controller.audioURL(lecture, lecture.parts[0]))
        let wav = try StoredAudio.playable(file, samples: 32000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let player = try AVAudioPlayer(contentsOf: wav)
        XCTAssertEqual(player.duration, 2, accuracy: 0.01)
        XCTAssertTrue(controller.history.contains { $0.id == lecture.id })
    }
    func testSenseVoiceCoreMLIOSBilingualAudio() async throws {
        let url = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main/test_wavs/0.wav")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "7d93384ca14702cc584a7a33fe2fed92e89e708549161cb12ea38c916882103b")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let samples = try StoredAudio.read(file, from: 0, count: 160850)
        let engine = SenseVoiceEngine()
        try await engine.load(language: "auto") { message, _ in print(message) }
        let text = try await engine.transcribe(samples)
        let left = try await engine.transcribe(samples, owned: 0..<80000)
        let right = try await engine.transcribe(samples, owned: 80000..<samples.count)
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        }
        XCTAssertEqual(normalized(left + right), normalized(text),
                       "Selecting both sides of a CTC seam must retain the full model output, including the final tail")
        await engine.unload()
        XCTAssertNotNil(text.range(of: "[A-Za-z]", options: .regularExpression))
        XCTAssertNotNil(text.range(of: "[\u{4e00}-\u{9fff}]", options: .regularExpression))
        print("PASS: iOS Core ML FP32 SenseVoice bilingual output: \(text)")
        var meeting = LectureSession(title: "公開音訊講者測試", model: "test", language: "auto")
        meeting.parts = [.init(fileName: file.lastPathComponent, offset: 0, sampleCount: samples.count)]
        let speakers = try await SpeakerAnalysis().analyze(meeting, files: [file]) { print($0) }
        XCTAssertFalse(speakers.turns.isEmpty, "Actual offline speaker model must return turns")
        XCTAssertTrue(speakers.turns.allSatisfy { $0.start >= 0 && $0.end <= meeting.duration && $0.end > $0.start })
        XCTAssertFalse(speakers.names.isEmpty)
        print("PASS: offline SpeakerKit model loaded and produced \(speakers.names.count) anonymous speaker labels")
        // This verifies the iOS Core ML CPU path, not WER or real-device latency.
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
        controller.liveDraft = "Yellow"
        XCTAssertEqual(controller.validTranslatedDraft, "")
        XCTAssertTrue(controller.translationCaption.contains("上次翻譯"), "Revising text keeps a clearly marked previous result without pairing it as current")
        controller.liveDraft = "Hello"
        controller.liveDraftStart = 10
        XCTAssertEqual(controller.validTranslatedDraft, "", "Repeated text at a new time needs its own translation")
        controller.translationDraftKey = controller.draftTranslationKey
        controller.restartTranslation()
        XCTAssertEqual(controller.validTranslatedDraft, "")
    }
}
