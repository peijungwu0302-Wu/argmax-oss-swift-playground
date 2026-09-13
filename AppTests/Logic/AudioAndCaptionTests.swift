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
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.8.0")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "13")
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

    func testSigningExpirationTimeFormattingSecondLevelPrecision() {
        // Must preserve full second-level precision without rounding to day, hour, minute
        let seconds: TimeInterval = 6 * 86400 + 23 * 3600 + 47 * 60 + 18
        let formatted = SigningTimeFormatter.formatRemaining(seconds: seconds)
        XCTAssertEqual(formatted, "6 天 23:47:18")

        let underOneDay: TimeInterval = 23 * 3600 + 47 * 60 + 18
        XCTAssertEqual(SigningTimeFormatter.formatRemaining(seconds: underOneDay), "23:47:18")

        XCTAssertEqual(SigningTimeFormatter.formatRemaining(seconds: 0), "已到期 00:00:00")
        XCTAssertEqual(SigningTimeFormatter.formatRemaining(seconds: -10), "已到期 00:00:00")

        // Expiration delta formatting
        XCTAssertEqual(SigningTimeFormatter.formatDelta(seconds: 27), "+27 秒")
        XCTAssertEqual(SigningTimeFormatter.formatDelta(seconds: -15), "-15 秒")
        XCTAssertEqual(SigningTimeFormatter.formatDelta(seconds: 0), "+0 秒")
    }

    func testSelfRefreshVerificationDiagnostics() {
        let beforeExp = Date(timeIntervalSince1970: 1789310172) // 14:36:12
        let afterExpRenewed = Date(timeIntervalSince1970: 1789310199) // 14:36:39 (+27s)
        let beforeCreation = Date(timeIntervalSince1970: 1788705372)
        let afterCreation = Date(timeIntervalSince1970: 1788705399)

        // Case 1: Successfully extended
        let diagSuccess = SelfRefreshDiagnostics(
            beforeExpirationDate: beforeExp,
            afterExpirationDate: afterExpRenewed,
            beforeCreationDate: beforeCreation,
            afterCreationDate: afterCreation,
            beforeProfileUUID: "uuid-1",
            afterProfileUUID: "uuid-2"
        )
        XCTAssertEqual(diagSuccess.status, .verified)
        XCTAssertTrue(diagSuccess.isExpirationExtended)
        XCTAssertEqual(diagSuccess.expirationDeltaSeconds, 27)
        XCTAssertEqual(diagSuccess.isUUIDChanged, true)
        XCTAssertEqual(diagSuccess.isCreationDateChanged, true)

        // Case 2: Expiration timestamp remains exactly unchanged -> NOT renewed
        let diagUnchanged = SelfRefreshDiagnostics(
            beforeExpirationDate: beforeExp,
            afterExpirationDate: beforeExp,
            beforeCreationDate: beforeCreation,
            afterCreationDate: afterCreation,
            beforeProfileUUID: "uuid-1",
            afterProfileUUID: "uuid-1"
        )
        XCTAssertEqual(diagUnchanged.status, .notRenewed)
        XCTAssertFalse(diagUnchanged.isExpirationExtended)
        XCTAssertEqual(diagUnchanged.expirationDeltaSeconds, 0)

        // Case 3: Expiration decreased -> NOT renewed
        let diagDecreased = SelfRefreshDiagnostics(
            beforeExpirationDate: beforeExp,
            afterExpirationDate: beforeExp.addingTimeInterval(-60)
        )
        XCTAssertEqual(diagDecreased.status, .notRenewed)
        XCTAssertFalse(diagDecreased.isExpirationExtended)
    }

    func testSigningProfileMobileProvisionParsing() {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key>
            <string>SideStore LectureTranscriber</string>
            <key>TeamName</key>
            <string>Peijung Wu</string>
            <key>UUID</key>
            <string>12345678-ABCD-EF01-2345-6789ABCDEF01</string>
            <key>CreationDate</key>
            <date>2026-09-13T14:36:12Z</date>
            <key>ExpirationDate</key>
            <date>2026-09-20T14:36:42Z</date>
        </dict>
        </plist>
        """
        var dummyContainer = Data([0x30, 0x82, 0x01, 0x00]) // Mock DER prefix
        dummyContainer.append(Data(sampleXML.utf8))
        dummyContainer.append(Data([0x00, 0x00])) // Mock DER suffix

        let profile = SigningProfile.parse(data: dummyContainer)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.name, "SideStore LectureTranscriber")
        XCTAssertEqual(profile?.teamName, "Peijung Wu")
        XCTAssertEqual(profile?.uuid, "12345678-ABCD-EF01-2345-6789ABCDEF01")
        XCTAssertNotNil(profile?.expirationDate)
        XCTAssertNotNil(profile?.creationDate)
    }

    func testResourceStateByteProgressFormatting() {
        let notDownloaded = ResourceState.notDownloaded
        XCTAssertEqual(notDownloaded.description, "尚未下載")
        XCTAssertNil(notDownloaded.progressValue)

        let downloadingWithTotal = ResourceState.downloading(bytesReceived: 52_428_800, totalBytes: 209_715_200, progress: 0.25)
        XCTAssertEqual(downloadingWithTotal.description, "下載中：50.0 MB / 200.0 MB (25%)")
        XCTAssertEqual(downloadingWithTotal.progressValue, 0.25)

        let downloadingWithoutTotal = ResourceState.downloading(bytesReceived: 31_457_280, totalBytes: nil, progress: 0)
        XCTAssertEqual(downloadingWithoutTotal.description, "下載中：已接收 30.0 MB")

        let ready = ResourceState.ready
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.progressValue, 1.0)
    }

    func testTranslationVersionPersistenceRoundtrip() throws {
        let line = TranscriptLine(start: 1.0, end: 3.5, text: "Artificial Intelligence in Healthcare")
        let transLine = TranslatedLine(id: line.id, source: line.text, text: "醫療領域的人工智慧")
        let tv = TranslationVersion(
            name: "Apple 離線即時翻譯",
            provider: "apple",
            sourceLocale: "en",
            targetLocale: "zh-Hant",
            lines: [transLine],
            isPreferred: true
        )
        let transcriptVersion = TranscriptVersion(
            name: "Whisper v3 轉錄",
            engine: .whisper,
            language: "en",
            lines: [line],
            translations: [transLine],
            source: .retranscription,
            isPreferred: true,
            translationVersions: [tv],
            preferredTranslationVersionID: tv.id
        )
        var session = LectureSession(
            title: "生醫 AI 專題",
            language: "en",
            transcriptVersions: [transcriptVersion],
            preferredVersionID: transcriptVersion.id
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(LectureSession.self, from: data)

        XCTAssertEqual(decoded.title, "生醫 AI 專題")
        XCTAssertEqual(decoded.transcriptVersions.count, 1)
        let decodedVer = decoded.transcriptVersions[0]
        XCTAssertEqual(decodedVer.translationVersions?.count, 1)
        XCTAssertEqual(decodedVer.translationVersions?[0].lines.first?.text, "醫療領域的人工智慧")
        XCTAssertEqual(decoded.translation(for: line)?.text, "醫療領域的人工智慧")
        XCTAssertEqual(decoded.translations?.first?.text, "醫療領域的人工智慧")
    }

    func testTranslationSpeedPresets() {
        XCTAssertEqual(TranslationSpeedPreset.ultraFast.defaultInterval, 0.25)
        XCTAssertEqual(TranslationSpeedPreset.fast.defaultInterval, 0.40)
        XCTAssertEqual(TranslationSpeedPreset.balanced.defaultInterval, 0.70)
        XCTAssertEqual(TranslationSpeedPreset.stable.defaultInterval, 1.00)
    }
}
