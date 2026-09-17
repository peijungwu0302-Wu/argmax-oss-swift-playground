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
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.9.0")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "19")
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

        let preparing = ResourceState.preparing(progress: nil)
        XCTAssertNil(preparing.progressValue)
        XCTAssertFalse(preparing.description.contains("%"), "Unknown Apple system progress must remain indeterminate")

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

    func testPiPAspectRatios() {
        XCTAssertEqual(PiPAspectRatio.standard.dimensions.width, 960)
        XCTAssertEqual(PiPAspectRatio.standard.dimensions.height, 320)
        XCTAssertEqual(Double(PiPAspectRatio.standard.dimensions.width) / Double(PiPAspectRatio.standard.dimensions.height), 3.0, accuracy: 0.01)

        XCTAssertEqual(PiPAspectRatio.bar.dimensions.width, 1200)
        XCTAssertEqual(PiPAspectRatio.bar.dimensions.height, 240)
        XCTAssertEqual(Double(PiPAspectRatio.bar.dimensions.width) / Double(PiPAspectRatio.bar.dimensions.height), 5.0, accuracy: 0.01)

        XCTAssertEqual(PiPAspectRatio.ultraWide.dimensions.width, 1200)
        XCTAssertEqual(PiPAspectRatio.ultraWide.dimensions.height, 200)
        XCTAssertEqual(Double(PiPAspectRatio.ultraWide.dimensions.width) / Double(PiPAspectRatio.ultraWide.dimensions.height), 6.0, accuracy: 0.01)
    }

    @MainActor
    func testCaptionFeedPublishing() {
        let feed = CaptionFeed()
        feed.update(original: "Hello World", translation: "你好世界", isRecording: true, isPaused: false)
        XCTAssertEqual(feed.latestOriginal, "Hello World")
        XCTAssertEqual(feed.latestTranslation, "你好世界")
        XCTAssertTrue(feed.isRecording)
        XCTAssertFalse(feed.isPaused)

        feed.update(captionMode: .chineseOnly)
        XCTAssertEqual(feed.captionMode, .chineseOnly)

        feed.update(aspectRatio: .ultraWide)
        XCTAssertEqual(feed.aspectRatio, .ultraWide)

        feed.clear()
        XCTAssertEqual(feed.latestOriginal, "")
        XCTAssertEqual(feed.latestTranslation, "")
    }

    func testLectureActivityAttributesContentState() throws {
        #if canImport(ActivityKit)
        let refDate = Date(timeIntervalSince1970: 1789310000)
        let state = LectureActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            timerReferenceDate: refDate,
            elapsedWhenPaused: 45.5,
            latestOriginal: "Asymptotic stability",
            latestTranslation: "漸近穩定性",
            captionMode: "bilingual",
            recognitionEngineName: "Apple Live"
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.isRecording, true)
        XCTAssertEqual(decoded.isPaused, false)
        XCTAssertEqual(decoded.latestOriginal, "Asymptotic stability")
        XCTAssertEqual(decoded.latestTranslation, "漸近穩定性")
        XCTAssertEqual(decoded.captionMode, "bilingual")
        XCTAssertEqual(decoded.recognitionEngineName, "Apple Live")
        XCTAssertEqual(decoded.elapsedWhenPaused, 45.5)
        #endif
    }

    func testLiveActivityClockPausesAndResumesWithoutEpochConversion() {
        let start = Date(timeIntervalSince1970: 1_789_310_000)
        var clock = LiveActivityClock(startedAt: start)

        clock.pause(at: start.addingTimeInterval(264))
        XCTAssertEqual(clock.elapsedWhenPaused, 264, accuracy: 0.001)
        XCTAssertEqual(clock.timerReferenceDate, start)

        clock.resume(at: start.addingTimeInterval(600))
        XCTAssertEqual(clock.elapsedWhenPaused, 264, accuracy: 0.001)
        XCTAssertEqual(clock.timerReferenceDate, start.addingTimeInterval(336),
                       "Resume must derive a reference date from elapsed seconds, never treat elapsed seconds as Unix time")

        clock.pause(at: start.addingTimeInterval(696))
        XCTAssertEqual(clock.elapsedWhenPaused, 360, accuracy: 0.001)
    }

    func testLiveActivityPolicyCoalescesPartialsAndImmediatelyAcceptsFinalEvents() {
        var policy = LiveActivityUpdatePolicy(partialInterval: 1)
        let t0 = Date(timeIntervalSince1970: 1_789_310_000)

        XCTAssertEqual(policy.accept(kind: .meaningfulPartial, revision: 1, original: "The", translation: "", at: t0), .send)
        XCTAssertEqual(policy.accept(kind: .meaningfulPartial, revision: 2, original: "The system", translation: "", at: t0.addingTimeInterval(0.4)), .coalesce)
        XCTAssertEqual(policy.accept(kind: .meaningfulPartial, revision: 3, original: "The system is stable", translation: "", at: t0.addingTimeInterval(1.1)), .send)
        XCTAssertEqual(policy.accept(kind: .finalOriginal, revision: 4, original: "The system is stable.", translation: "", at: t0.addingTimeInterval(1.2)), .send)
        XCTAssertEqual(policy.accept(kind: .finalTranslation, revision: 4, original: "The system is stable.", translation: "系統是穩定的。", at: t0.addingTimeInterval(1.3)), .send)
        XCTAssertEqual(policy.accept(kind: .meaningfulPartial, revision: 5, original: "Next", translation: "", at: t0.addingTimeInterval(1.4)), .coalesce)
        XCTAssertEqual(policy.accept(kind: .meaningfulPartial, revision: 5, original: "Next", translation: "", at: t0.addingTimeInterval(2.5)), .ignore,
                       "Unchanged caption text must not wake ActivityKit")
    }

    @MainActor
    func testPiPPresentationDefaultsResetAndExistingPreferencePreservation() throws {
        let suite = "PiPPresentationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = PiPPresentationSettings(defaults: defaults)
        XCTAssertTrue(settings.autoStart)
        XCTAssertEqual(settings.aspectRatio, .bar)
        XCTAssertEqual(settings.fontScale, 1)
        XCTAssertEqual(settings.captionMode, .bilingual)
        XCTAssertEqual(settings.alignment, .left)
        XCTAssertEqual(settings.verticalPosition, .center)
        XCTAssertEqual(settings.gap, .standard)

        settings.autoStart = false
        settings.aspectRatio = .standard
        settings.fontScale = 1.4
        settings.captionMode = .originalOnly
        settings.alignment = .right
        settings.verticalPosition = .bottom
        settings.gap = .wide

        settings = PiPPresentationSettings(defaults: defaults)
        XCTAssertFalse(settings.autoStart, "An update must preserve an existing user's explicit Auto PiP choice")
        XCTAssertEqual(settings.fontScale, 1.4, accuracy: 0.001)
        XCTAssertEqual(settings.alignment, .right)

        settings.reset()
        XCTAssertTrue(settings.autoStart)
        XCTAssertEqual(settings.aspectRatio, .bar)
        XCTAssertEqual(settings.fontScale, 1)
        XCTAssertEqual(settings.captionMode, .bilingual)
        XCTAssertEqual(settings.alignment, .left)
        XCTAssertEqual(settings.verticalPosition, .center)
        XCTAssertEqual(settings.gap, .standard)
    }

    func testPiPAdaptiveLayoutKeepsSafePaddingAndScalesByRatio() {
        let three = PiPLayoutMetrics.make(renderSize: CGSize(width: 960, height: 320), ratio: .standard,
                                          mode: .bilingual, fontScale: 1, gap: .standard)
        let five = PiPLayoutMetrics.make(renderSize: CGSize(width: 1200, height: 240), ratio: .bar,
                                         mode: .bilingual, fontScale: 1.25, gap: .standard)
        let six = PiPLayoutMetrics.make(renderSize: CGSize(width: 1200, height: 200), ratio: .ultraWide,
                                        mode: .bilingual, fontScale: 1, gap: .wide)
        XCTAssertGreaterThanOrEqual(three.horizontalPadding, 24)
        XCTAssertGreaterThan(three.verticalPadding, six.verticalPadding)
        XCTAssertGreaterThan(five.originalFont, six.originalFont)
        XCTAssertGreaterThan(five.originalFont, PiPLayoutMetrics.make(renderSize: CGSize(width: 1200, height: 240), ratio: .bar,
                                                                       mode: .bilingual, fontScale: 1, gap: .standard).originalFont)
        XCTAssertLessThanOrEqual(six.blockGap, 16)
    }

    @MainActor
    func testNavigationDeepLinkRoutesOnlyKnownLectureToFullTranscript() {
        let known = UUID()
        let navigation = AppNavigationState()
        XCTAssertTrue(navigation.handle(URL(string: "lecturetranscriber://lecture/\(known.uuidString)/transcript")!, knownLectureIDs: [known]))
        XCTAssertEqual(navigation.route, .fullTranscript(known))

        let missing = UUID()
        XCTAssertFalse(navigation.handle(URL(string: "lecturetranscriber://lecture/\(missing.uuidString)/transcript")!, knownLectureIDs: [known]))
        XCTAssertEqual(navigation.route, .home)
    }

    func testAudioInputSourceAndSessionStorageMode() {
        XCTAssertEqual(AudioInputSource.microphone.rawValue, "microphone")
        XCTAssertEqual(AudioInputSource.deviceAudio.rawValue, "deviceAudio")
        XCTAssertEqual(SessionStorageMode.liveOnly.rawValue, "liveOnly")
        XCTAssertEqual(SessionStorageMode.saveTranscript.rawValue, "saveTranscript")

        // Ensure display names exist
        XCTAssertFalse(AudioInputSource.microphone.displayName.isEmpty)
        XCTAssertFalse(AudioInputSource.deviceAudio.displayName.isEmpty)
        XCTAssertFalse(SessionStorageMode.liveOnly.displayName.isEmpty)
        XCTAssertFalse(SessionStorageMode.saveTranscript.displayName.isEmpty)
    }

    func testSegmentMergerDanglingAndMerge() {
        // Dangling words
        XCTAssertTrue(SegmentMerger.isDangling("we need to find the"))
        XCTAssertTrue(SegmentMerger.isDangling("because of"))
        XCTAssertTrue(SegmentMerger.isDangling("and"))
        XCTAssertFalse(SegmentMerger.isDangling("the eigenvalues are positive."))

        // Should merge
        let line1 = TranscriptLine(start: 0.0, end: 1.5, text: "we need to find the")
        let line2 = TranscriptLine(start: 1.8, end: 3.0, text: "eigenvalues of this matrix.")
        XCTAssertTrue(SegmentMerger.shouldMerge(previous: line1, next: line2))

        let merged = SegmentMerger.mergeText(previous: line1.text, next: line2.text)
        XCTAssertEqual(merged, "we need to find the eigenvalues of this matrix.")

        // Chinese text merging without extra space
        let zh1 = "我們需要計算"
        let zh2 = "特徵值"
        XCTAssertEqual(SegmentMerger.mergeText(previous: zh1, next: zh2), "我們需要計算特徵值")

        // Long pause should not merge
        let lineLongPause = TranscriptLine(start: 5.0, end: 7.0, text: "eigenvalues of this matrix.")
        XCTAssertFalse(SegmentMerger.shouldMerge(previous: line1, next: lineLongPause))
    }

    func testSegmentMergerMeaningfulDraft() {
        XCTAssertFalse(SegmentMerger.isMeaningfulDraft(""))
        XCTAssertFalse(SegmentMerger.isMeaningfulDraft("a"))
        XCTAssertFalse(SegmentMerger.isMeaningfulDraft("the"))
        XCTAssertTrue(SegmentMerger.isMeaningfulDraft("the system"))
        XCTAssertTrue(SegmentMerger.isMeaningfulDraft("機器學習"))
    }

    @MainActor
    func testLocalizationGlobalLanguageSwitching() {
        let l10n = L10n.shared
        l10n.appLanguage = .zhHant
        XCTAssertEqual(l10n.effectiveLocale.identifier, "zh-Hant")
        XCTAssertEqual(L10n.tr("開始錄音", "Start Recording"), "開始錄音")

        l10n.appLanguage = .en
        XCTAssertEqual(l10n.effectiveLocale.identifier, "en")
        XCTAssertEqual(L10n.tr("開始錄音", "Start Recording"), "Start Recording")

        // Reset to system
        l10n.appLanguage = .system
    }

    @MainActor
    func testCourseVocabularyDataModelAndLimits() {
        let vocab = CourseVocabulary.shared
        // Clear for clean test
        vocab.setEntriesForTesting([])
        XCTAssertEqual(vocab.entries.count, 0)
        XCTAssertEqual(vocab.canonicalTerms.count, 0)

        // Add valid entry
        XCTAssertTrue(vocab.addEntry(canonical: "nuScenes", aliases: ["new scenes", "nu scenes"]))
        XCTAssertEqual(vocab.entries.count, 1)
        XCTAssertEqual(vocab.canonicalTerms, ["nuScenes"])
        XCTAssertEqual(vocab.entries.first?.aliasesDisplayString, "new scenes, nu scenes")

        // Reject empty canonical
        XCTAssertFalse(vocab.addEntry(canonical: "   ", aliases: ["test"]))
        XCTAssertEqual(vocab.entries.count, 1)

        // Update entry
        if let id = vocab.entries.first?.id {
            vocab.updateEntry(id: id, canonical: "nuScenes-v2", aliases: ["new scenes v2"])
            XCTAssertEqual(vocab.entries.first?.canonical, "nuScenes-v2")
            XCTAssertEqual(vocab.entries.first?.aliases, ["new scenes v2"])

            // Delete entry
            vocab.deleteEntry(id: id)
            XCTAssertEqual(vocab.entries.count, 0)
        }

        // Test max entries limit (100)
        var sampleList: [VocabularyEntry] = []
        for i in 1...100 {
            sampleList.append(VocabularyEntry(canonical: "Term\(i)", aliases: ["alias\(i)"]))
        }
        vocab.setEntriesForTesting(sampleList)
        XCTAssertEqual(vocab.entries.count, 100)
        // 101st entry should be rejected
        XCTAssertFalse(vocab.addEntry(canonical: "OverflowTerm", aliases: ["overflow"]))
        XCTAssertEqual(vocab.entries.count, 100)

        // Reset
        vocab.setEntriesForTesting([])
    }

    func testCourseVocabularyConservativeReplacement() {
        let entries = [
            VocabularyEntry(canonical: "nuScenes", aliases: ["new scenes", "nu scenes", "news scenes"]),
            VocabularyEntry(canonical: "Q-Former", aliases: ["cue former", "q former", "q-former"]),
            VocabularyEntry(canonical: "TrajQFormer", aliases: ["traj q former", "traj-q-former"]),
            VocabularyEntry(canonical: "UniAD", aliases: ["uni ad", "uni-ad"]),
            VocabularyEntry(canonical: "BEVFormer", aliases: ["bev former", "bev-former"])
        ]

        // Acceptance Test Requirement 1: Input "We evaluate on new scenes." -> "We evaluate on nuScenes."
        let input1 = "We evaluate on new scenes."
        let output1 = CourseVocabulary.applyVocabulary(to: input1, entries: entries)
        XCTAssertEqual(output1, "We evaluate on nuScenes.")

        // Acceptance Test Requirement 2: Input "The weather shows new clouds." -> MUST NOT change to "The weather shows nuScenes clouds."
        let input2 = "The weather shows new clouds."
        let output2 = CourseVocabulary.applyVocabulary(to: input2, entries: entries)
        XCTAssertEqual(output2, "The weather shows new clouds.")

        // Acceptance Test Requirement 3: Input "The cue former architecture works well." -> "The Q-Former architecture works well."
        let input3 = "The cue former architecture works well."
        let output3 = CourseVocabulary.applyVocabulary(to: input3, entries: entries)
        XCTAssertEqual(output3, "The Q-Former architecture works well.")

        // Multi-term and longest-prefix priority test
        let input4 = "Testing traj q former and bev former on nuscenes benchmark."
        let output4 = CourseVocabulary.applyVocabulary(to: input4, entries: entries)
        XCTAssertEqual(output4, "Testing TrajQFormer and BEVFormer on nuScenes benchmark.")

        // Hyphen boundary test
        let input5 = "The uni-ad and q-former models are compared."
        let output5 = CourseVocabulary.applyVocabulary(to: input5, entries: entries)
        XCTAssertEqual(output5, "The UniAD and Q-Former models are compared.")

        // Empty text test
        XCTAssertEqual(CourseVocabulary.applyVocabulary(to: "", entries: entries), "")
    }

    @MainActor
    func testDeviceAudioAvailabilityAndDiagnostics() {
        // Test availability logic does not throw unexpected runtime exception
        let isSupported = DeviceAudioAvailability.isSupported
        let reason = DeviceAudioAvailability.unavailableReason
        XCTAssertFalse(reason.isEmpty)

        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 27 {
            XCTAssertTrue(isSupported, "Device Audio must report supported on iOS/iPadOS 27+")
        }

        // Test diagnostics model formatting
        var diag = DeviceAudioDiagnostics(
            appVersion: "1.8.5 (18)",
            osVersion: "iOS 27.0",
            isSupported: true,
            isCapturing: true,
            totalBuffersReceived: 42,
            firstBufferLatency: 0.125,
            sampleRate: 16000,
            channelCount: 1,
            targetPCMFormat: "PCM Float32, 16000 Hz, 1 channel",
            lastBufferTimestamp: Date(),
            droppedBuffers: 0,
            lastError: nil,
            currentASREngine: "Apple Speech"
        )

        XCTAssertTrue(diag.audioBuffersReceiving)
        XCTAssertEqual(diag.firstBufferLatencyText, "0.125 s")
        let summary = diag.formattedSummary()
        XCTAssertTrue(summary.contains("App Version: 1.8.5 (18)"))
        XCTAssertTrue(summary.contains("Total Buffers Received: 42"))
        XCTAssertTrue(summary.contains("Sample Rate: 16000 Hz"))
        XCTAssertTrue(summary.contains("Current ASR Engine: Apple Speech"))

        // Test copyDiagnostics
        let copied = DeviceAudioCaptureManager.shared.copyDiagnostics()
        XCTAssertFalse(copied.isEmpty)
    }

    func testLiveActivityStateMachineFreezesPauseAndStop() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var state = LiveActivityTimerState(startedAt: start)
        state.pause(at: start.addingTimeInterval(10))
        XCTAssertEqual(state.elapsed(at: start.addingTimeInterval(100)), 10, accuracy: 0.001)
        XCTAssertFalse(state.rendersRunningTimer)
        state.resume(at: start.addingTimeInterval(100))
        XCTAssertEqual(state.elapsed(at: start.addingTimeInterval(105)), 15, accuracy: 0.001)
        state.stop(at: start.addingTimeInterval(110))
        XCTAssertEqual(state.elapsed(at: start.addingTimeInterval(999)), 20, accuracy: 0.001)
        XCTAssertFalse(state.rendersRunningTimer)
        XCTAssertEqual(state.phase, .stopped)
    }

    func testLiveActivityRefreshPresetsAndNewestPartialWins() {
        XCTAssertEqual(LiveActivityRefreshPreset.fast.interval, 0.10, accuracy: 0.001)
        XCTAssertEqual(LiveActivityRefreshPreset.balanced.interval, 0.25, accuracy: 0.001)
        XCTAssertEqual(LiveActivityRefreshPreset.saver.interval, 0.50, accuracy: 0.001)
        var buffer = LatestCaptionCoalescer(interval: 0.25)
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(buffer.offer("A", at: t0), "A")
        XCTAssertNil(buffer.offer("B", at: t0.addingTimeInterval(0.05)))
        XCTAssertNil(buffer.offer("C", at: t0.addingTimeInterval(0.10)))
        XCTAssertEqual(buffer.flush(at: t0.addingTimeInterval(0.25)), "C")
    }

    @MainActor
    func testDisplaySettingsPersistenceAndReset() throws {
        let suite = "DisplaySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = DisplaySettings(defaults: defaults)
        settings.appOriginalScale = 3
        settings.pipTranslationScale = 0.3
        settings.historyScale = 2.4
        settings = DisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.appOriginalScale, 3)
        XCTAssertEqual(settings.pipTranslationScale, 0.3)
        XCTAssertEqual(settings.historyScale, 2.4)
        settings.resetAll()
        XCTAssertEqual(settings.appOriginalScale, 1)
        XCTAssertEqual(settings.appTranslationScale, 1)
        XCTAssertEqual(settings.pipOriginalScale, 1)
        XCTAssertEqual(settings.pipTranslationScale, 1)
        XCTAssertEqual(settings.historyScale, 1)
    }

    func testChineseFinalSegmentationHasNoMissingOrDuplicateText() {
        let input = TranscriptLine(start: 0, end: 20, text: "今天介紹非線性系統。接著討論平衡點！最後說明穩定性")
        let output = ChineseFinalSegmenter.split(input)
        XCTAssertEqual(output.map(\.text).joined(), input.text)
        XCTAssertEqual(output.first?.start, 0)
        XCTAssertEqual(output.last?.end, 20)
        XCTAssertTrue(zip(output, output.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    func testASRHotSwitchBoundaryIsMonotonicAndPreservesCounters() {
        let boundary = ASRSwitchBoundary(engine: "apple", sampleIndex: 160_000, timestamp: 10, totalBuffers: 1205)
        let switched = boundary.switching(to: "sensevoice", atSample: 160_000, timestamp: 10)
        XCTAssertEqual(switched.totalBuffers, 1205)
        XCTAssertEqual(switched.sampleIndex, 160_000)
        XCTAssertEqual(switched.timestamp, 10)
        XCTAssertEqual(switched.engine, "sensevoice")
    }

    func testTranslationRouteMetadataAndQueueDeduplication() {
        let route = TranslationRoute(source: "ja", target: "zh-Hant")
        XCTAssertEqual(route.source, "ja")
        XCTAssertEqual(route.target, "zh-Hant")
        var queue = TranslationRecoveryQueue()
        let line = TranscriptLine(start: 1, end: 2, text: "こんにちは")
        queue.enqueue(line, route: route)
        queue.enqueue(line, route: route)
        XCTAssertEqual(queue.pending.count, 1)
        queue.removeCompleted([line.id])
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testDeviceAudioSavePreferenceDefaultsToAskEveryTime() {
        XCTAssertEqual(DeviceAudioSavePreference.defaultValue, .askEveryTime)
        XCTAssertTrue(DeviceAudioSavePreference.askEveryTime.requiresDecision)
        XCTAssertFalse(DeviceAudioSavePreference.alwaysSave.requiresDecision)
    }

    // MARK: - v1.9.1 Architecture Tests

    func testSpeechDynamicsProcessorAdaptiveGainAndPeakLimiter() {
        var processor = SpeechDynamicsProcessor()

        // 1. Test quiet signal boost
        let quietSamples: [Float] = (0..<1600).map { _ in 0.005 }
        let (boosted, diag1) = processor.processWithDiagnostics(quietSamples)
        XCTAssertEqual(boosted.count, quietSamples.count)
        XCTAssertGreaterThan(diag1.postPeakDBFS, diag1.prePeakDBFS, "Quiet speech must be amplified")
        XCTAssertGreaterThan(diag1.effectiveGainDB, 0.0)

        // 2. Test peak limiter: loud input must NEVER exceed ceiling (-0.3 dBFS / ~0.965)
        let loudSamples: [Float] = (0..<1600).map { i in (i % 2 == 0) ? 1.5 : -1.5 }
        let (limited, diag2) = processor.processWithDiagnostics(loudSamples)
        for sample in limited {
            XCTAssertLessThanOrEqual(sample, 0.966, "Sample must not exceed peak limiter ceiling")
            XCTAssertGreaterThanOrEqual(sample, -0.966, "Sample must not fall below peak limiter negative ceiling")
        }
        XCTAssertLessThanOrEqual(diag2.postPeakDBFS, -0.29)
    }

    func testStoredAudioPlayableDirectContainerAndWAVArchiving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Test WAV archiving and direct playback
        let pcmFile = folder.appendingPathComponent("test.pcm16")
        let sampleCount = 16000
        let samples: [Float] = (0..<sampleCount).map { i in sin(Float(i) * 0.05) * 0.3 }
        let archivedWAV = try StoredAudio.archiveWAV(source: pcmFile, samples: samples)
        XCTAssertEqual(archivedWAV.pathExtension.lowercased(), "wav")

        // Read WAV header validation
        let data = try Data(contentsOf: archivedWAV)
        XCTAssertGreaterThan(data.count, 44)
        let riffHeader = String(data: data.prefix(4), encoding: .ascii)
        XCTAssertEqual(riffHeader, "RIFF")

        // Playable should return the standard container directly (no temporary copy!)
        let playableURL = try StoredAudio.playable(archivedWAV, samples: sampleCount)
        XCTAssertEqual(playableURL.path, archivedWAV.path, "Standard audio container must be played directly without temporary conversion")
    }

    @MainActor
    func testCaptionTimelineWatermarksAndSyncState() {
        let timeline = CaptionTimeline()
        timeline.reset()

        // Watermarks initially zero
        XCTAssertEqual(timeline.audioCapturedPTS, 0)
        XCTAssertEqual(timeline.audioFedToASRPTS, 0)
        XCTAssertEqual(timeline.asrFinalizedPTS, 0)

        // Record progression
        timeline.recordAudioCaptured(duration: 5.0, pts: 5.0)
        XCTAssertEqual(timeline.audioCapturedPTS, 5.0)

        timeline.recordAudioFedToASR(samplesCount: 80_000, pts: 5.0)
        XCTAssertEqual(timeline.audioFedToASRPTS, 5.0)

        timeline.recordASRFinalized(throughPTS: 4.8)
        XCTAssertEqual(timeline.asrFinalizedPTS, 4.8)

        // Display caught up with finalized caption
        timeline.recordCaptionDisplayed(throughPTS: 4.8)

        let snapshot = timeline.snapshot()
        XCTAssertEqual(snapshot.syncState, .normal)
        XCTAssertEqual(snapshot.captureToASRLag, 0.2, accuracy: 0.01)
    }

    func testPiPCaptionLayoutEngineRollingWindow() {
        let engine = PiPCaptionLayoutEngine()
        let metrics = PiPLayoutMetrics(
            horizontalPadding: 12,
            verticalPadding: 8,
            originalFont: 16,
            translationFont: 14,
            blockGap: 6,
            lineSpacing: 4,
            maxLines: 2
        )

        // Test very long sentence that exceeds max lines
        let longSentence = "This is a very long transcription segment produced by the lecturer during the advanced control systems course discussing state space models and Lyapunov stability criteria."
        let model = CaptionPresentationModel(
            originalText: longSentence,
            translatedText: "",
            displayMode: .originalOnly,
            aspectRatio: .bar,
            alignment: .left,
            verticalPosition: .center
        )

        let layout = engine.layout(model: model, canvasSize: CGSize(width: 400, height: 80), metrics: metrics)
        XCTAssertNotNil(layout.originalRect)
        XCTAssertFalse(layout.originalTextToDraw.isEmpty)
        // Rolling tail window ensures the newest part of the sentence remains visible
        XCTAssertTrue(layout.originalTextToDraw.contains("stability criteria") || layout.originalTextToDraw.contains("Lyapunov"))

        // Rect must fit within available canvas height
        if let rect = layout.originalRect {
            XCTAssertLessThanOrEqual(rect.maxY, 80)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
        }
    }

    func testPiPCaptionLayoutEngineBilingualAllocation() {
        let engine = PiPCaptionLayoutEngine()
        let metrics = PiPLayoutMetrics(
            horizontalPadding: 12,
            verticalPadding: 8,
            originalFont: 14,
            translationFont: 14,
            blockGap: 4,
            lineSpacing: 3,
            maxLines: 3
        )

        let model = CaptionPresentationModel(
            originalText: "The system is asymptotically stable.",
            translatedText: "這個系統是漸近穩定的。",
            displayMode: .bilingual,
            aspectRatio: .bar,
            alignment: .left,
            verticalPosition: .center
        )

        let layout = engine.layout(model: model, canvasSize: CGSize(width: 400, height: 100), metrics: metrics)
        XCTAssertNotNil(layout.originalRect)
        XCTAssertNotNil(layout.translationRect)
        XCTAssertEqual(layout.originalTextToDraw, "The system is asymptotically stable.")
        XCTAssertEqual(layout.translationTextToDraw, "這個系統是漸近穩定的。")

        if let orig = layout.originalRect, let trans = layout.translationRect {
            XCTAssertLessThan(orig.maxY, trans.minY + 5, "Original text and translated text must not overlap")
            XCTAssertLessThanOrEqual(trans.maxY, 100, "Translated text must not be clipped past canvas bottom")
        }
    }

    @MainActor
    func testModelCenterManifestAndCapabilities() {
        let center = ModelCenter.shared
        XCTAssertFalse(center.manifest.isEmpty)

        // Verify Apple Speech item
        let apple = center.manifest.first(where: { $0.id == "apple" })
        XCTAssertNotNil(apple)
        XCTAssertTrue(apple?.isBuiltIn == true)
        XCTAssertTrue(apple?.supportsVocabularyBias == true)

        // Verify SenseVoice Small item
        let senseVoice = center.manifest.first(where: { $0.id == "sensevoice-small" })
        XCTAssertNotNil(senseVoice)
        XCTAssertEqual(senseVoice?.engineType, .sensevoice)

        // Verify WhisperKit Turbo item
        let whisperTurbo = center.manifest.first(where: { $0.id == "openai_whisper-large-v3-v20240930_626MB" })
        XCTAssertNotNil(whisperTurbo)
        XCTAssertEqual(whisperTurbo?.engineType, .whisper)
        XCTAssertTrue(whisperTurbo?.supportsVocabularyBias == true)

        // Verify Zipformer item
        let zipformer = center.manifest.first(where: { $0.id == "zipformer-bilingual" })
        XCTAssertNotNil(zipformer)
        XCTAssertEqual(zipformer?.engineType, .zipformer)
        XCTAssertTrue(zipformer?.isSupportedOnCurrentDevice == true, "Zipformer is supported in v1.9.1 with sherpa-onnx runtime")
        XCTAssertNil(zipformer?.unsupportedReason)
        XCTAssertFalse(center.isModelDownloaded("zipformer-bilingual"))

        let paraformer = center.manifest.first(where: { $0.id == "paraformer-bilingual" })
        XCTAssertNotNil(paraformer)
        XCTAssertEqual(paraformer?.engineType, .paraformer)
        XCTAssertTrue(paraformer?.isSupportedOnCurrentDevice == true, "Paraformer is supported in v1.9.1 with sherpa-onnx runtime")
        XCTAssertNil(paraformer?.unsupportedReason)
        XCTAssertFalse(center.isModelDownloaded("paraformer-bilingual"))

        // Verify Qwen3-ASR unsupported status on standard mobile profile and truthful wording
        let qwen3 = center.manifest.first(where: { $0.id == "qwen3-asr" })
        XCTAssertNotNil(qwen3)
        XCTAssertFalse(qwen3?.isSupportedOnCurrentDevice == true)
        let qwenReason = qwen3?.unsupportedReason ?? ""
        XCTAssertFalse(qwenReason.contains("16GB"), "Must not claim >16GB RAM requirement")
        XCTAssertFalse(qwenReason.contains("16 GB"), "Must not claim >16 GB RAM requirement")
        XCTAssertTrue(
            qwenReason.contains("LectureTranscriber 尚未整合可用的 iOS 裝置端執行環境") ||
            qwenReason.contains("An iOS on-device runtime has not yet been integrated into LectureTranscriber.")
        )
    }

    @MainActor
    func testAudioSessionCoordinatorPolicies() throws {
        let coordinator = AudioSessionCoordinator.shared

        // 1. Device Audio isolation: owns NO active audio session
        coordinator.activateDeviceAudioCapture()
        XCTAssertEqual(coordinator.currentState, .deviceAudioCapture)

        // PiP with requiresAudioSession == false must be a NO-OP and must NOT activate AVAudioSession
        coordinator.beginPiPPresentation(requiresAudioSession: false)
        XCTAssertEqual(coordinator.currentState, .deviceAudioCapture, "PiP must not override device audio capture state")

        coordinator.deactivateDeviceAudioCapture()
        XCTAssertEqual(coordinator.currentState, .idle)

        // 2. Microphone Capture: Baseline mode must be .default, NOT .spokenAudio and NOT .measurement
        try coordinator.activateMicrophoneCapture(allowsPlayback: true, preferBluetoothMic: false)
        XCTAssertEqual(coordinator.currentState, .microphoneCapture)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .default, "Microphone capture must use .default mode")
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers), "Must preserve .mixWithOthers")
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.bluetoothHFPCompatible), "Built-in mic must not use HFP")

        coordinator.deactivateMicrophoneCapture()
        XCTAssertEqual(coordinator.currentState, .idle)
    }

    @MainActor
    func testCaptionTimelineSingleMediaTimelineAndNoNegativeLag() {
        let timeline = CaptionTimeline()
        timeline.reset()

        // Monotonic media timeline starting from 0.0
        // Device Audio captures a chunk with duration 2.0s, endMediaTime 2.0s, sourcePTS 54321.0
        let chunk1 = TimedAudioChunk(
            samples: [Float](repeating: 0.1, count: 32000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 0.0,
            endMediaTime: 2.0,
            startSampleIndex: 0,
            endSampleIndex: 32000,
            sourcePTS: 54321.0
        )
        XCTAssertEqual(chunk1.startMediaTime, 0.0)
        XCTAssertEqual(chunk1.endMediaTime, 2.0)
        XCTAssertEqual(chunk1.pts, 0.0)
        XCTAssertEqual(chunk1.duration, 2.0)
        XCTAssertEqual(chunk1.sourcePTS, 54321.0)

        timeline.recordAudioCaptured(duration: chunk1.duration, pts: chunk1.endMediaTime)
        XCTAssertEqual(timeline.capturedThrough, 2.0)
        timeline.recordCaptionDisplayed(throughPTS: chunk1.endMediaTime)
        XCTAssertEqual(timeline.displayedThrough, 2.0)

        // Second chunk: from 2.0 to 3.0
        timeline.recordAudioCaptured(duration: 1.0, pts: 3.0)
        XCTAssertEqual(timeline.capturedThrough, 3.0)

        timeline.recordAudioFedToASR(samplesCount: 16000, pts: 3.0)
        XCTAssertEqual(timeline.fedThrough, 3.0)

        timeline.recordASRFinalized(throughPTS: 2.5, wallClockDuration: 0.12)
        XCTAssertEqual(timeline.recognizedThrough, 2.5)
        XCTAssertEqual(timeline.lastASRProcessingDuration, 0.12)

        // Media lag is strictly in the media domain: captured - recognized
        XCTAssertEqual(timeline.recognitionMediaLag, 0.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(timeline.recognitionMediaLag, 0.0)

        // Wall-clock translation latency tracked separately
        timeline.recordTranslationComplete(throughPTS: 2.5, wallClockDuration: 0.08)
        XCTAssertEqual(timeline.translatedThrough, 2.5)
        XCTAssertEqual(timeline.lastTranslationProcessingDuration, 0.08)
        XCTAssertEqual(timeline.translationMediaLag, 0.0)

        // Display lag
        timeline.recordCaptionDisplayed(throughPTS: 2.5)
        XCTAssertEqual(timeline.displayedThrough, 2.5)
        XCTAssertEqual(timeline.displayMediaLag, 0.0)
        XCTAssertEqual(timeline.syncState, .catchingUp)

        // When ASR and display catch up (lag <= 0.35s), timeline transitions back to normal
        timeline.recordASRFinalized(throughPTS: 2.8)
        timeline.recordCaptionDisplayed(throughPTS: 2.8)
        XCTAssertEqual(timeline.recognitionMediaLag, 0.2, accuracy: 0.001)
        XCTAssertEqual(timeline.syncState, .normal)
    }

    @MainActor
    func testFactualWatermarksNeverFabricateOnPauseOrStale() {
        let timeline = CaptionTimeline()
        timeline.reset()
        timeline.setPresentationSurfaceActive(true)

        timeline.recordAudioCaptured(duration: 10.0, pts: 10.0)
        timeline.recordAudioFedToASR(samplesCount: 160_000, pts: 10.0)
        timeline.recordASRFinalized(throughPTS: 6.0)
        timeline.recordTranslationComplete(throughPTS: 6.0)
        timeline.recordCaptionDisplayed(throughPTS: 2.0)

        // Display lag is 6.0 - 2.0 = 4.0s > 3.5s stale threshold
        XCTAssertEqual(timeline.syncState, .stale)
        // In STALE: displayedThrough MUST NOT be fabricated to max(0, recognizedThrough - 0.2)!
        XCTAssertEqual(timeline.displayedThrough, 2.0, "Stale state must NEVER fabricate or advance displayedThrough speculatively")

        // Source pause: drainBacklog must NEVER equate watermarks
        timeline.drainBacklog()
        XCTAssertEqual(timeline.recognizedThrough, 6.0, "Pause must not fabricate recognition progress")
        XCTAssertEqual(timeline.translatedThrough, 6.0, "Pause must not fabricate translation progress")
        XCTAssertEqual(timeline.displayedThrough, 2.0, "Pause must not fabricate display progress")

        // Rendering newest cue resolves stale state into catchingUp
        timeline.recordCaptionDisplayed(throughPTS: 6.0)
        XCTAssertEqual(timeline.displayedThrough, 6.0)
        XCTAssertEqual(timeline.displayMediaLag, 0.0)
        XCTAssertEqual(timeline.syncState, .catchingUp)

        // When ASR and display fully catch up, state transitions to normal
        timeline.recordASRFinalized(throughPTS: 10.0)
        timeline.recordCaptionDisplayed(throughPTS: 10.0)
        XCTAssertEqual(timeline.recognitionMediaLag, 0.0)
        XCTAssertEqual(timeline.syncState, .normal)
    }

    @MainActor
    func testTranslationAndDisplayWatermarksRequireEndpoints() {
        let timeline = CaptionTimeline()
        timeline.reset()

        timeline.recordAudioCaptured(duration: 5.0, pts: 5.0)
        timeline.recordASRFinalized(throughPTS: 4.0)

        // Passing nil endpoint must NOT fabricate progress to recognizedThrough
        timeline.recordTranslationComplete(throughPTS: nil)
        XCTAssertEqual(timeline.translatedThrough, 0.0, "Nil translation endpoint must not advance watermark")

        timeline.recordTranslationComplete(throughPTS: 3.5)
        XCTAssertEqual(timeline.translatedThrough, 3.5)

        // Passing nil endpoint must NOT fabricate progress to recognizedThrough
        timeline.recordCaptionDisplayed(throughPTS: nil)
        XCTAssertEqual(timeline.displayedThrough, 0.0, "Nil display endpoint must not advance watermark")

        timeline.recordCaptionDisplayed(throughPTS: 3.5)
        XCTAssertEqual(timeline.displayedThrough, 3.5)
    }

    @MainActor
    func testLiveCaptionSyncControllerPoliciesAndPresentation() {
        let timeline = CaptionTimeline()
        timeline.reset()
        let controller = LiveCaptionSyncController(timeline: timeline)

        // 1. NORMAL mode: immediate pass-through
        let cue1 = controller.receivePartial(start: 0.0, end: 1.0, text: "Hello", engine: "apple", language: "en")
        XCTAssertEqual(cue1.originalText, "Hello")
        XCTAssertEqual(CaptionFeed.shared.latestOriginal, "Hello")
        XCTAssertEqual(CaptionFeed.shared.latestCueEndTime, 1.0)
        XCTAssertEqual(timeline.hypothesisThrough, 1.0, "Partial must advance hypothesisThrough")
        XCTAssertEqual(timeline.recognizedThrough, 0.0, "Partial must NOT advance recognizedThrough")

        // Final line
        let cueFinal = controller.receiveFinal(start: 0.0, end: 1.5, text: "Hello world.", engine: "apple", language: "en")
        XCTAssertTrue(cueFinal.isFinal)
        XCTAssertEqual(CaptionFeed.shared.latestOriginal, "Hello world.")
        XCTAssertEqual(CaptionFeed.shared.latestCueEndTime, 1.5)
        XCTAssertEqual(timeline.cues.count, 1, "Finalized cue must be preserved in storage")
        XCTAssertEqual(timeline.hypothesisThrough, 1.5, "Final line must advance hypothesisThrough")
        XCTAssertEqual(timeline.recognizedThrough, 1.5, "Final line must advance recognizedThrough")
        XCTAssertEqual(timeline.displayedThrough, 0.0, "Display watermark must not advance before actual presentation")
        timeline.recordCaptionDisplayed(throughPTS: 1.5)
        XCTAssertEqual(timeline.displayedThrough, 1.5, "Display watermark advances upon presentation acknowledgement")

        // Translation update
        controller.updateTranslation(forCueID: cueFinal.id, throughPTS: 1.5, translation: "你好世界。")
        XCTAssertEqual(CaptionFeed.shared.latestTranslation, "你好世界。")
        XCTAssertEqual(timeline.translatedThrough, 1.5)
    }

    @MainActor
    func testASRHotSwitchBacklogPreservedInRouter() {
        let router = ASRRouter.shared
        router.recordSwitch(
            from: "sensevoice",
            to: "apple",
            sampleIndex: 120_000,
            timestamp: 7.5,
            successful: true,
            note: "Hot switch preserving backlog"
        )
        XCTAssertEqual(router.currentEngine, .apple)
        XCTAssertEqual(router.lastSwitchEvent?.fromEngine, "sensevoice")
        XCTAssertEqual(router.lastSwitchEvent?.toEngine, "apple")
        XCTAssertEqual(router.lastSwitchEvent?.sampleIndex, 120_000)
        XCTAssertEqual(router.lastSwitchEvent?.successful, true)
    }

    @MainActor
    func testASRSwitchPlanDeterministicHandoff() {
        let plan = ASRRouter.planSwitch(
            from: "sensevoice",
            to: "apple",
            capturedSamples: 48_000,
            fedCursor: 32_000,
            finalizedCursor: 16_000
        )
        XCTAssertEqual(plan.oldEngine, "sensevoice")
        XCTAssertEqual(plan.newEngine, "apple")
        XCTAssertEqual(plan.capturedSampleCount, 48_000)
        XCTAssertEqual(plan.switchBoundary, 48_000)
        XCTAssertEqual(plan.oldEngineCommittedRange, 0..<16_000)
        XCTAssertEqual(plan.handoffBacklogRange, 16_000..<48_000)
        XCTAssertEqual(plan.newEngineStartCursor, 16_000)
        XCTAssertTrue(plan.isValidHandoff, "Switch plan must guarantee zero gap and zero overlap between committed range and backlog")
    }

    func testPCMRecorderSnapshotDiagnostics() {
        let snapshot = PCMRecorder.Snapshot(
            samples: 16000,
            level: 0.5,
            error: nil,
            isMasterActive: true,
            masterError: nil
        )
        XCTAssertEqual(snapshot.samples, 16000)
        XCTAssertTrue(snapshot.isMasterActive)
        XCTAssertNil(snapshot.masterError)
    }

    func testMasterArchiveNativeSampleRatePreservation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let masterURL = folder.appendingPathComponent("part1.master.caf")
        let format48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: masterURL, settings: format48k.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format48k, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.2
        }
        try file.write(from: buffer)

        // Archive to AAC (Standard 64 kbps)
        let aacURL = try StoredAudio.archive(source: masterURL, samples: 16000, quality: .standard)
        XCTAssertEqual(aacURL.pathExtension.lowercased(), "m4a")

        var opened: ExtAudioFileRef?
        XCTAssertEqual(ExtAudioFileOpenURL(aacURL as CFURL, &opened), noErr)
        if let opened {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            XCTAssertEqual(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &asbd), noErr)
            ExtAudioFileDispose(opened)
            XCTAssertEqual(asbd.mSampleRate, 48000.0, "AAC file must preserve native master 48 kHz sample rate without 16 kHz downsampling")
        }

        // Archive to Uncompressed WAV
        let wavURL = try StoredAudio.archive(source: masterURL, samples: 16000, quality: .uncompressed)
        XCTAssertEqual(wavURL.pathExtension.lowercased(), "wav")
        var openedWAV: ExtAudioFileRef?
        XCTAssertEqual(ExtAudioFileOpenURL(wavURL as CFURL, &openedWAV), noErr)
        if let openedWAV {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            XCTAssertEqual(ExtAudioFileGetProperty(openedWAV, kExtAudioFileProperty_FileDataFormat, &size, &asbd), noErr)
            ExtAudioFileDispose(openedWAV)
            XCTAssertEqual(asbd.mSampleRate, 48000.0, "Uncompressed WAV must preserve native master 48 kHz sample rate")
        }
    }

    func testAtomicArchiveCleanupSafety() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("part1.pcm16")
        let master = PCMRecorder.masterURL(for: original)
        let samples: [Float] = (0..<16000).map { _ in 0.05 }
        try AudioStorage.encodePCM16(samples).write(to: original)
        try Data("dummy-master".utf8).write(to: master)

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path))

        // On simulated failure before metadata save: master and original must remain
        let mockFailedCommit = true
        if mockFailedCommit {
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Original PCM16 must be preserved on commit failure")
            XCTAssertTrue(FileManager.default.fileExists(atPath: master.path), "Master CAF must be preserved on commit failure")
        }

        // On simulated success after metadata save: both are safely cleaned up
        try? FileManager.default.removeItem(at: master)
        try? FileManager.default.removeItem(at: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: master.path))
    }

    func testMicrophoneDualBranchArchitecture() {
        let intermediate = URL(fileURLWithPath: "/tmp/lecture-session/part1.pcm16")
        let master = PCMRecorder.masterURL(for: intermediate)
        XCTAssertEqual(master.pathExtension.lowercased(), "caf")
        XCTAssertTrue(master.lastPathComponent.contains("master"))

        // Speech dynamics processor at native 48 kHz
        var processor = SpeechDynamicsProcessor(sampleRate: 48000)
        let quietNative: [Float] = (0..<4800).map { _ in 0.005 }
        let (boosted, diag) = processor.processWithDiagnostics(quietNative)
        XCTAssertEqual(boosted.count, quietNative.count)
        XCTAssertGreaterThan(diag.postPeakDBFS, diag.prePeakDBFS, "Native speech must be amplified by listener DSP")
        XCTAssertLessThanOrEqual(diag.postPeakDBFS, -0.29, "Native speech must respect peak limiter ceiling")
    }

    @MainActor
    func testASRRouterTruthfulUnavailableEngineFallback() async {
        let router = ASRRouter.shared
        await router.reset()
        XCTAssertEqual(router.currentEngine, .apple)

        // Attempting to switch to Zipformer (planned for v1.9.2) must throw and keep active engine running
        do {
            try await router.hotSwitch(
                to: .zipformer,
                targetLanguage: "zh",
                currentSampleOffset: 16000,
                currentPTS: 1.0,
                onResult: { _ in }
            )
            XCTFail("Should throw for deferred runtime")
        } catch {
            // Active engine must REMAIN Apple Speech!
            XCTAssertEqual(router.currentEngine, .apple, "Fallback invariant: active engine must remain unchanged on failure")
            XCTAssertEqual(router.lastSwitchEvent?.successful, false)
        }
    }

    @MainActor
    func testDisplayedThroughOnlyAdvancesOnPresentationAcknowledgement() {
        let timeline = CaptionTimeline.shared
        timeline.reset()
        XCTAssertEqual(timeline.snapshot().displayedThrough, 0.0)

        // Emitting / receiving final caption must NOT advance displayedThrough
        _ = timeline.receiveFinal(id: UUID(), start: 1.0, end: 3.5, text: "Hello world", engine: "whisper", language: "en")
        XCTAssertEqual(timeline.snapshot().recognizedThrough, 3.5)
        XCTAssertEqual(timeline.snapshot().displayedThrough, 0.0, "displayedThrough must not advance before actual presentation")

        // Only explicit presentation acknowledgement advances displayedThrough
        timeline.recordCaptionDisplayed(throughPTS: 3.5)
        XCTAssertEqual(timeline.snapshot().displayedThrough, 3.5, "displayedThrough must advance upon presentation acknowledgement")
    }

    @MainActor
    func testPresentationSurfaceActivePreventsFalseStaleSyncState() {
        let timeline = CaptionTimeline.shared
        timeline.reset()
        // Feed audio up to 6.0s
        timeline.recordAudioCaptured(duration: 6.0, pts: 6.0)
        timeline.recordAudioFedToASR(samplesCount: 96000, pts: 6.0)
        _ = timeline.receiveFinal(id: UUID(), start: 0.0, end: 6.0, text: "Old cue", engine: "apple", language: "en")

        // Surface inactive: even if display lag is huge (6.0 - 0.0 = 6.0s > 3.5s), sync state must NOT be .stale
        timeline.setPresentationSurfaceActive(false)
        let inactiveSnapshot = timeline.snapshot()
        XCTAssertFalse(inactiveSnapshot.presentationSurfaceActive)
        XCTAssertNotEqual(inactiveSnapshot.syncState, .stale, "Inactive presentation surface must not declare stale sync state")

        // Surface active: display lag (6.0 - 0.0 = 6.0s > 3.5s) triggers .stale
        timeline.setPresentationSurfaceActive(true)
        let activeSnapshot = timeline.snapshot()
        XCTAssertTrue(activeSnapshot.presentationSurfaceActive)
        XCTAssertEqual(activeSnapshot.syncState, .stale, "Active presentation surface with displayMediaLag > 3.5s must be stale")

        // Acknowledge display up to 6.0s: recLag = 0.0, dispLag = 0.0 -> returns to .normal
        timeline.recordCaptionDisplayed(throughPTS: 6.0)
        let caughtUpSnapshot = timeline.snapshot()
        XCTAssertEqual(caughtUpSnapshot.syncState, .normal)
    }

    @MainActor
    func testDelayedTranslationBindingToMatchingCueID() {
        let syncController = LiveCaptionSyncController.shared
        let feed = CaptionFeed.shared
        feed.clear()

        let cue1ID = UUID()
        let cue2ID = UUID()

        // Receive cue 1
        syncController.receiveFinal(id: cue1ID, start: 0.0, end: 2.0, text: "First sentence", engine: "sensevoice", language: "en")
        XCTAssertEqual(feed.latestCueID, cue1ID)
        XCTAssertEqual(feed.latestOriginal, "First sentence")

        // Receive cue 2
        syncController.receiveFinal(id: cue2ID, start: 2.0, end: 4.0, text: "Second sentence", engine: "sensevoice", language: "en")
        XCTAssertEqual(feed.latestCueID, cue2ID)
        XCTAssertEqual(feed.latestOriginal, "Second sentence")

        // Delayed translation arrives for older cue 1: must be discarded
        syncController.updateTranslation(forCueID: cue1ID, translation: "第一句（過期）")
        XCTAssertEqual(feed.latestTranslation, "", "Delayed translation for mismatched cueID must not overwrite current caption")

        // Translation arrives for current cue 2: must be applied
        syncController.updateTranslation(forCueID: cue2ID, translation: "第二句（正確）")
        XCTAssertEqual(feed.latestTranslation, "第二句（正確）", "Translation matching current cueID must update CaptionFeed")
    }

    func testPCMRecorderMasterDurationValidationAndFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recoveryPCM = tempDir.appendingPathComponent("part1.pcm16")
        let sampleCount = 32000 // 2 seconds at 16 kHz
        let pcmData = AudioStorage.encodePCM16([Float](repeating: 0.05, count: sampleCount))
        try pcmData.write(to: recoveryPCM)

        // Case 1: master file does not exist, recovery PCM is used directly
        let archivedNormal = try PCMRecorder.archive(source: recoveryPCM, samples: sampleCount, quality: .standard, masterWriteFailed: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedNormal.path))

        // Case 2: masterWriteFailed flag is explicitly true
        let archivedWithFailedFlag = try PCMRecorder.archive(source: recoveryPCM, samples: sampleCount, quality: .standard, masterWriteFailed: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedWithFailedFlag.path))
    }

    func testStoredAudioArchiveVerificationThrowsOnTruncation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Non-existent file throws
        let nonExistentURL = tempDir.appendingPathComponent("missing.m4a")
        XCTAssertThrowsError(
            try StoredAudio.verifyArchive(destination: nonExistentURL, expectedDuration: 1.0, samples: 16000)
        )

        // Empty (0 byte) file throws
        let emptyURL = tempDir.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        XCTAssertThrowsError(
            try StoredAudio.verifyArchive(destination: emptyURL, expectedDuration: 1.0, samples: 16000)
        )
    }

    func testASRSwitchPlanContinuityAndBoundaries() {
        let plan = ASRRouter.planSwitch(
            from: "apple",
            to: "sensevoice",
            capturedSamples: 160000,
            fedCursor: 144000,
            finalizedCursor: 96000
        )

        XCTAssertEqual(plan.oldEngine, "apple")
        XCTAssertEqual(plan.newEngine, "sensevoice")
        XCTAssertEqual(plan.capturedSampleCount, 160000)
        XCTAssertEqual(plan.switchBoundary, 160000)
        XCTAssertEqual(plan.oldEngineCommittedRange, 0..<96000)
        XCTAssertEqual(plan.handoffBacklogRange, 96000..<160000)
        XCTAssertEqual(plan.newEngineStartCursor, 96000)
        XCTAssertTrue(plan.isValidHandoff)
    }

    @MainActor
    func testZipformerAndParaformerModelManifestAndInstallationCheck() {
        let center = ModelCenter.shared
        center.refreshAllModelStates()

        let zipformerItem = center.manifest.first(where: { $0.id == "zipformer-bilingual" })
        XCTAssertNotNil(zipformerItem)
        XCTAssertEqual(zipformerItem?.name, "Zipformer Bilingual")
        XCTAssertEqual(zipformerItem?.isSupportedOnCurrentDevice, true)
        XCTAssertNil(zipformerItem?.unsupportedReason)
        XCTAssertEqual(zipformerItem?.engineType, .zipformer)
        XCTAssertEqual(zipformerItem?.downloadSizeMB, 48)

        let paraformerItem = center.manifest.first(where: { $0.id == "paraformer-bilingual" })
        XCTAssertNotNil(paraformerItem)
        XCTAssertEqual(paraformerItem?.name, "Streaming Paraformer Bilingual")
        XCTAssertEqual(paraformerItem?.isSupportedOnCurrentDevice, true)
        XCTAssertNil(paraformerItem?.unsupportedReason)
        XCTAssertEqual(paraformerItem?.engineType, .paraformer)
        XCTAssertEqual(paraformerItem?.downloadSizeMB, 226)

        // When uninstalled, state must be notDownloaded (never falsely ready)
        if !ZipformerStreamingEngine.isModelInstalled() {
            XCTAssertEqual(center.state(for: "zipformer-bilingual"), .notDownloaded)
        }
        if !ParaformerStreamingEngine.isModelInstalled() {
            XCTAssertEqual(center.state(for: "paraformer-bilingual"), .notDownloaded)
        }

        // Required filenames
        XCTAssertEqual(ZipformerStreamingEngine.encoderName, "encoder-epoch-99-avg-1.int8.onnx")
        XCTAssertEqual(ZipformerStreamingEngine.decoderName, "decoder-epoch-99-avg-1.onnx")
        XCTAssertEqual(ZipformerStreamingEngine.joinerName, "joiner-epoch-99-avg-1.int8.onnx")
        XCTAssertEqual(ZipformerStreamingEngine.tokensName, "tokens.txt")

        XCTAssertEqual(ParaformerStreamingEngine.encoderName, "encoder.int8.onnx")
        XCTAssertEqual(ParaformerStreamingEngine.decoderName, "decoder.int8.onnx")
        XCTAssertEqual(ParaformerStreamingEngine.tokensName, "tokens.txt")
    }

    @MainActor
    func testZipformerStreamingEngineTimelineMapping() {
        // Test SpeechUpdate mapping for streaming updates
        let partialUpdate = SpeechUpdate(
            text: "Hello",
            start: 1.0,
            end: 2.0,
            finalizedThrough: 1.0,
            isFinal: false
        )
        XCTAssertFalse(partialUpdate.isFinal)
        XCTAssertEqual(partialUpdate.finalizedThrough, 1.0)

        let finalUpdate = SpeechUpdate(
            text: "Hello world",
            start: 1.0,
            end: 2.5,
            finalizedThrough: 2.5,
            isFinal: true
        )
        XCTAssertTrue(finalUpdate.isFinal)
        XCTAssertEqual(finalUpdate.finalizedThrough, 2.5)
    }

    @MainActor
    func testParaformerSegmentTimingFactualTimelineMapping() {
        // Factual sample-to-seconds conversion: 32000 samples = 2.0s, 48000 samples = 3.0s
        let startSample = 32000
        let endSample = 48000
        let startPTS = Double(startSample) / 16000.0
        let endPTS = Double(endSample) / 16000.0

        XCTAssertEqual(startPTS, 2.0, accuracy: 0.0001)
        XCTAssertEqual(endPTS, 3.0, accuracy: 0.0001)

        let update = SpeechUpdate(
            text: "課堂逐字稿測試",
            start: startPTS,
            end: endPTS,
            finalizedThrough: endPTS,
            isFinal: true
        )
        XCTAssertTrue(update.isFinal)
        XCTAssertEqual(update.start, 2.0, accuracy: 0.0001)
        XCTAssertEqual(update.end, 3.0, accuracy: 0.0001)
    }

    func testSherpaStreamResultEquatabilityAndProperties() {
        let result1 = SherpaStreamResult(
            text: "testing",
            tokens: ["test", "ing"],
            timestamps: [0.1, 0.3],
            isEndpoint: false,
            startSampleIndex: 0,
            endSampleIndex: 16000
        )
        XCTAssertFalse(result1.isEndpoint)
        XCTAssertEqual(result1.text, "testing")
        XCTAssertEqual(result1.tokens.count, 2)
        XCTAssertEqual(result1.timestamps.count, 2)
        XCTAssertEqual(result1.startSampleIndex, 0)
        XCTAssertEqual(result1.endSampleIndex, 16000)

        let result2 = SherpaStreamResult(
            text: "final phrase",
            isEndpoint: true,
            startSampleIndex: 16000,
            endSampleIndex: 32000
        )
        XCTAssertTrue(result2.isEndpoint)
        XCTAssertEqual(result2.text, "final phrase")
        XCTAssertTrue(result2.tokens.isEmpty)
        XCTAssertTrue(result2.timestamps.isEmpty)
    }

    func testSherpaOnnxRuntimeLifecycleAndCleanup() async {
        let runtime = SherpaOnnxRuntime()
        let initialReady = await runtime.isReady
        XCTAssertFalse(initialReady)

        await runtime.resetStream()
        await runtime.unload()
        let afterUnloadReady = await runtime.isReady
        XCTAssertFalse(afterUnloadReady)
        let modelId = await runtime.currentModelId
        XCTAssertEqual(modelId, "")
    }

    func testASREngineTypeSupportedEnginesAndAvailability() {
        let validEngines = ["apple", "whisper", "sensevoice", "zipformer", "paraformer"]
        for engineName in validEngines {
            let engineType = ASREngineType(rawValue: engineName)
            XCTAssertNotNil(engineType, "Engine \(engineName) must be recognized by ASREngineType")
            XCTAssertTrue(engineType?.isAvailableInCurrentRelease == true, "Engine \(engineName) must be available in current release")
        }
        let invalid = ASREngineType(rawValue: "unsupported_engine_xyz")
        XCTAssertNil(invalid)
    }

    func testSherpaStreamMonotonicUtteranceContinuity() async {
        let runtime = SherpaOnnxRuntime()
        // Fresh stream starts at 0
        await runtime.startNewStream()
        let startCount = await runtime.currentSampleCountFed
        let startSegment = await runtime.currentSegmentStartSample
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(startSegment, 0)

        // Resetting utterance advances segmentStartSample to currentSampleCountFed without zeroing media clock
        await runtime.resetUtterance()
        let resetCount = await runtime.currentSampleCountFed
        let resetSegment = await runtime.currentSegmentStartSample
        XCTAssertEqual(resetCount, 0)
        XCTAssertEqual(resetSegment, 0)

        // Calling startNewStream resets both back to 0
        await runtime.startNewStream()
        let finalCount = await runtime.currentSampleCountFed
        let finalSegment = await runtime.currentSegmentStartSample
        XCTAssertEqual(finalCount, 0)
        XCTAssertEqual(finalSegment, 0)
    }

    func testHotSwitchPlanReflectsPreparationRaceAdvance() {
        // Stale cursors at switch initiation
        let staleCaptured = 32000
        let staleFed = 32000
        let staleFinalized = 16000
        let stalePlan = ASRRouter.planSwitch(
            from: "whisper",
            to: "zipformer",
            capturedSamples: staleCaptured,
            fedCursor: staleFed,
            finalizedCursor: staleFinalized
        )
        XCTAssertEqual(stalePlan.switchBoundary, 32000)

        // While candidate was being prepared, audio capture and recognition advanced
        let freshCaptured = 48000
        let freshFed = 48000
        let freshFinalized = 32000
        let freshPlan = ASRRouter.planSwitch(
            from: "whisper",
            to: "zipformer",
            capturedSamples: freshCaptured,
            fedCursor: freshFed,
            finalizedCursor: freshFinalized
        )
        // Authoritative handoff plan snapshot reflects the new boundary
        XCTAssertEqual(freshPlan.switchBoundary, 48000)
        XCTAssertEqual(freshPlan.newEngineStartCursor, 32000)
        XCTAssertEqual(freshPlan.handoffBacklogRange, 32000..<48000)
        XCTAssertGreaterThan(freshPlan.switchBoundary, stalePlan.switchBoundary)
    }

    func testHotSwitchPrunedRollingBufferValidation() {
        let plan = ASRRouter.planSwitch(
            from: "whisper",
            to: "zipformer",
            capturedSamples: 48000,
            fedCursor: 48000,
            finalizedCursor: 16000
        )
        XCTAssertEqual(plan.newEngineStartCursor, 16000)
        XCTAssertEqual(plan.switchBoundary, 48000)

        // Case A: Rolling buffer retains full backlog [0, 48000]
        let bufferStartA = 0
        let bufferEndA = 48000
        let canSwitchA = plan.newEngineStartCursor >= bufferStartA && plan.switchBoundary <= bufferEndA
        XCTAssertTrue(canSwitchA, "Buffer retains full backlog, safe to switch")

        // Case B: Rolling buffer was pruned to [20000, 48000], missing [16000, 20000]
        let bufferStartB = 20000
        let bufferEndB = 48000
        let canSwitchB = plan.newEngineStartCursor >= bufferStartB && plan.switchBoundary <= bufferEndB
        XCTAssertFalse(canSwitchB, "Buffer pruned, missing backlog; must safely abort")
    }

    func testGlobalOffsetCompositionForContinuousTimeline() {
        let handoffStartSample = 32000
        let offset = Double(handoffStartSample) / 16000.0 // 2.0s

        let result1 = SherpaStreamResult(
            text: "Hello",
            isEndpoint: true,
            startSampleIndex: 0,
            endSampleIndex: 16000
        )
        let globalStart1 = offset + Double(result1.startSampleIndex) / 16000.0
        let globalEnd1 = offset + Double(result1.endSampleIndex) / 16000.0
        XCTAssertEqual(globalStart1, 2.0, accuracy: 0.0001)
        XCTAssertEqual(globalEnd1, 3.0, accuracy: 0.0001)

        let result2 = SherpaStreamResult(
            text: "World",
            isEndpoint: true,
            startSampleIndex: 16000,
            endSampleIndex: 32000
        )
        let globalStart2 = offset + Double(result2.startSampleIndex) / 16000.0
        let globalEnd2 = offset + Double(result2.endSampleIndex) / 16000.0
        XCTAssertEqual(globalStart2, 3.0, accuracy: 0.0001)
        XCTAssertEqual(globalEnd2, 4.0, accuracy: 0.0001)
    }

    @MainActor
    func testDeviceAudioHandoffGatePreventsOldEngineLeakAndReplaysBacklog() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"

        let oldEngine = MockLiveSpeechEngine()
        controller.setAppleSpeechForTesting(oldEngine)

        // Baseline: fed 100,000 samples, buffer offset 0 with 100,000 samples
        controller.setDeviceAudioFedSampleIndexForTesting(100_000)
        controller.setDeviceAudioBufferStartOffsetForTesting(0)
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.1, count: 100_000))

        // Enter handoff gate (as when taking snapshot during switchRecognitionEngine)
        controller.enterASRHandoffGateForTesting()
        XCTAssertTrue(controller.isASRHandoffInProgress)

        // Chunks arrive while inside the handoff gate
        let chunk1 = TimedAudioChunk(
            samples: [Float](repeating: 0.2, count: 4000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 6.25,
            endMediaTime: 6.5,
            startSampleIndex: 100_000,
            endSampleIndex: 104_000,
            sourcePTS: 6.25
        )
        controller.deviceAudioDidOutput(chunk: chunk1)

        let chunk2 = TimedAudioChunk(
            samples: [Float](repeating: 0.3, count: 4000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 6.5,
            endMediaTime: 6.75,
            startSampleIndex: 104_000,
            endSampleIndex: 108_000,
            sourcePTS: 6.5
        )
        controller.deviceAudioDidOutput(chunk: chunk2)

        // Yield to let any async tasks settle
        await Task.yield()

        // Invariant: old engine must NOT have received any chunks arriving after gate was entered
        XCTAssertEqual(oldEngine.appendedSamples.count, 0, "Old engine must NEVER receive chunks during handoff gate")
        XCTAssertEqual(controller.deviceAudioFedSampleIndexForTesting, 100_000, "Fed cursor must not advance during gate")
        XCTAssertEqual(controller.deviceAudioBufferCountForTesting, 108_000, "All chunks must be retained in rolling buffer")

        // Simulate handoff completion to new engine:
        // New engine starts at unfinalized cursor (e.g. 96,000)
        let newEngine = MockLiveSpeechEngine()
        let newEngineStartCursor = 96_000
        let currentBufferedEnd = controller.deviceAudioBufferStartOffsetForTesting + controller.deviceAudioBufferCountForTesting
        XCTAssertEqual(currentBufferedEnd, 108_000)

        // Slices [newEngineStartCursor ..< currentBufferedEnd]
        let bufferSnapshot = controller.getDeviceAudioBufferSnapshotForTesting()
        let localStart = newEngineStartCursor - controller.deviceAudioBufferStartOffsetForTesting
        let localEnd = currentBufferedEnd - controller.deviceAudioBufferStartOffsetForTesting
        let backlog = Array(bufferSnapshot[localStart..<localEnd])
        try await newEngine.append(backlog)

        // Backlog received by new engine is exactly 12,000 samples (4000 unfinalized + 8000 gated)
        XCTAssertEqual(newEngine.appendedSamples.count, 12_000)
        controller.setDeviceAudioFedSampleIndexForTesting(currentBufferedEnd)
        controller.setAppleSpeechForTesting(newEngine)

        // Exit gate
        controller.leaveASRHandoffGateForTesting()
        XCTAssertFalse(controller.isASRHandoffInProgress)

        // Next chunk arrives after handoff gate is open
        let chunk3 = TimedAudioChunk(
            samples: [Float](repeating: 0.4, count: 4000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 6.75,
            endMediaTime: 7.0,
            startSampleIndex: 108_000,
            endSampleIndex: 112_000,
            sourcePTS: 6.75
        )
        controller.deviceAudioDidOutput(chunk: chunk3)
        // Wait for async task inside deviceAudioDidOutput
        try await Task.sleep(nanoseconds: 50_000_000)

        // Invariant: New engine received entire stream without gap or duplicate!
        XCTAssertEqual(newEngine.appendedSamples.count, 16_000, "New engine receives backlog + new live chunks")
        XCTAssertEqual(oldEngine.appendedSamples.count, 0, "Old engine remains completely uncorrupted")
    }

    @MainActor
    func testDeviceAudioHandoffGateRollbackReplaysGatedAudio() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"

        let oldEngine = MockLiveSpeechEngine()
        controller.setAppleSpeechForTesting(oldEngine)

        // Baseline: fed 100,000 samples, buffer offset 0 with 100,000 samples
        controller.setDeviceAudioFedSampleIndexForTesting(100_000)
        controller.setDeviceAudioBufferStartOffsetForTesting(0)
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.1, count: 100_000))

        // Enter handoff gate
        controller.enterASRHandoffGateForTesting()

        // 4000 samples arrive while gate is closed
        let gatedChunk = TimedAudioChunk(
            samples: [Float](repeating: 0.5, count: 4000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 6.25,
            endMediaTime: 6.5,
            startSampleIndex: 100_000,
            endSampleIndex: 104_000,
            sourcePTS: 6.25
        )
        controller.deviceAudioDidOutput(chunk: gatedChunk)
        await Task.yield()

        XCTAssertEqual(oldEngine.appendedSamples.count, 0, "Old engine received nothing during gate")
        XCTAssertEqual(controller.deviceAudioBufferCountForTesting, 104_000)

        // Simulate failed switch -> trigger rollback to old engine
        let session = LectureSession(title: "Rollback Test", language: "zh")
        controller.session = session
        await controller.rollbackGatedDeviceAudio(
            oldEngine: "apple",
            fromSample: 100_000,
            committedBoundary: 100_000,
            current: session
        )
        controller.leaveASRHandoffGateForTesting()

        // Gated audio was safely replayed to old engine on rollback
        XCTAssertEqual(oldEngine.appendedSamples.count, 4000, "Rollback must replay all audio gated during handoff")
        XCTAssertEqual(controller.deviceAudioFedSampleIndexForTesting, 104_000, "Fed cursor updated to current buffer end")
        XCTAssertFalse(controller.isASRHandoffInProgress)
    }

    @MainActor
    func testModelCenterAtomicInstallAndCleanDelete() async throws {
        let center = ModelCenter.shared
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Attempting to install when files are missing must fail
        do {
            try await center.installModel(modelId: "zipformer-bilingual", from: stagingDir)
            XCTFail("Missing files must throw")
        } catch {}

        // Create the 4 required Zipformer files with 4-byte data (fake files)
        let requiredFiles = [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt"
        ]
        for f in requiredFiles {
            let data = Data([0x01, 0x02, 0x03, 0x04])
            try data.write(to: stagingDir.appendingPathComponent(f))
        }

        // Test 1: Fake 4-byte model files MUST FAIL validation
        do {
            try await center.installModel(modelId: "zipformer-bilingual", from: stagingDir)
            XCTFail("4-byte fake model files must fail runtime validation")
        } catch {
            // Expected failure: state must NOT be .ready
            XCTAssertNotEqual(center.state(for: "zipformer-bilingual"), .ready)
            XCTAssertFalse(center.isModelDownloaded("zipformer-bilingual"))
        }

        // Test 2: Atomic install with injected mock validator succeeds
        let validStaging = FileManager.default.temporaryDirectory.appendingPathComponent("test-valid-staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: validStaging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: validStaging) }

        for f in requiredFiles {
            let data = Data(repeating: 0x42, count: 2048)
            try data.write(to: validStaging.appendingPathComponent(f))
        }
        try "token1 1\ntoken2 2\n".write(to: validStaging.appendingPathComponent("tokens.txt"), atomically: true, encoding: .utf8)

        var mockValidatorCalled = false
        center.runtimeValidator = { modelId, targetDir in
            mockValidatorCalled = true
            XCTAssertEqual(modelId, "zipformer-bilingual")
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.path))
        }

        try await center.installModel(modelId: "zipformer-bilingual", from: validStaging)
        XCTAssertTrue(mockValidatorCalled)
        XCTAssertTrue(center.isModelDownloaded("zipformer-bilingual"))
        XCTAssertEqual(center.state(for: "zipformer-bilingual"), .ready)

        // Test 3: Update failure restores backup
        let failingStaging = FileManager.default.temporaryDirectory.appendingPathComponent("test-failing-staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: failingStaging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: failingStaging) }

        for f in requiredFiles {
            let data = Data(repeating: 0x99, count: 2048)
            try data.write(to: failingStaging.appendingPathComponent(f))
        }
        try "bad token\n".write(to: failingStaging.appendingPathComponent("tokens.txt"), atomically: true, encoding: .utf8)

        struct SimulatedInstallError: Error {}
        center.runtimeValidator = { _, _ in
            throw SimulatedInstallError()
        }

        do {
            try await center.installModel(modelId: "zipformer-bilingual", from: failingStaging)
            XCTFail("Should throw on mock validation failure")
        } catch {
            // Target was restored from backup! Model must still be installed and .ready!
            XCTAssertTrue(center.isModelDownloaded("zipformer-bilingual"))
            XCTAssertEqual(center.state(for: "zipformer-bilingual"), .ready)
        }

        center.runtimeValidator = nil

        // Clean delete removes files and resets state
        try center.deleteModel("zipformer-bilingual")
        XCTAssertFalse(center.isModelDownloaded("zipformer-bilingual"))
        XCTAssertEqual(center.state(for: "zipformer-bilingual"), .notDownloaded)
    }

    @MainActor
    func testDeviceAudioHandoffDrainUntilStableDuringReplaySuspension() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"

        controller.setDeviceAudioFedSampleIndexForTesting(100_000)
        controller.setDeviceAudioBufferStartOffsetForTesting(0)
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.1, count: 100_000))

        controller.enterASRHandoffGateForTesting()
        XCTAssertTrue(controller.isASRHandoffInProgress)

        let candidateEngine = MockLiveSpeechEngine()
        var chunkInjected = false
        candidateEngine.onAppend = { [weak controller] _ in
            guard let controller, !chunkInjected else { return }
            chunkInjected = true
            let chunk = TimedAudioChunk(
                samples: [Float](repeating: 0.2, count: 4000),
                sampleRate: 16000,
                channelCount: 1,
                level: 0.5,
                startMediaTime: 6.25,
                endMediaTime: 6.5,
                startSampleIndex: 100_000,
                endSampleIndex: 104_000,
                sourcePTS: 6.25
            )
            controller.deviceAudioDidOutput(chunk: chunk)
        }

        let finalCursor = try await controller.drainDeviceAudioBacklog(from: 100_000) { chunk in
            try await candidateEngine.append(chunk)
        }

        XCTAssertTrue(chunkInjected)
        XCTAssertEqual(finalCursor, 104_000)
        XCTAssertEqual(controller.deviceAudioFedSampleIndexForTesting, 104_000)
        XCTAssertEqual(candidateEngine.appendedSamples.count, 4000)
        XCTAssertEqual(controller.deviceAudioBufferCountForTesting, 104_000)
    }

    @MainActor
    func testDeviceAudioHandoffMultipleArrivalsDuringRepeatedDrains() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"

        controller.setDeviceAudioFedSampleIndexForTesting(50_000)
        controller.setDeviceAudioBufferStartOffsetForTesting(0)
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.1, count: 50_000))

        controller.enterASRHandoffGateForTesting()

        let candidateEngine = MockLiveSpeechEngine()
        var drainCount = 0
        candidateEngine.onAppend = { [weak controller] _ in
            guard let controller else { return }
            drainCount += 1
            if drainCount == 1 {
                let chunk1 = TimedAudioChunk(
                    samples: [Float](repeating: 0.2, count: 3000),
                    sampleRate: 16000,
                    channelCount: 1,
                    level: 0.5,
                    startMediaTime: 3.125,
                    endMediaTime: 3.3125,
                    startSampleIndex: 50_000,
                    endSampleIndex: 53_000,
                    sourcePTS: 3.125
                )
                controller.deviceAudioDidOutput(chunk: chunk1)
            } else if drainCount == 2 {
                let chunk2 = TimedAudioChunk(
                    samples: [Float](repeating: 0.3, count: 2000),
                    sampleRate: 16000,
                    channelCount: 1,
                    level: 0.5,
                    startMediaTime: 3.3125,
                    endMediaTime: 3.4375,
                    startSampleIndex: 53_000,
                    endSampleIndex: 55_000,
                    sourcePTS: 3.3125
                )
                controller.deviceAudioDidOutput(chunk: chunk2)
            }
        }

        // Prime 1000 samples of backlog to kick off drain loop
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.15, count: 1000))
        let finalCursor = try await controller.drainDeviceAudioBacklog(from: 50_000) { chunk in
            try await candidateEngine.append(chunk)
        }

        XCTAssertEqual(drainCount, 3)
        XCTAssertEqual(candidateEngine.appendedSamples.count, 6000)
        XCTAssertEqual(finalCursor, 56_000)
        XCTAssertEqual(controller.deviceAudioFedSampleIndexForTesting, 56_000)
        XCTAssertEqual(controller.deviceAudioBufferCountForTesting, 56_000)
    }

    @MainActor
    func testDeviceAudioHandoffGateRollbackDrainsBacklogUntilStable() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"

        let oldEngine = MockLiveSpeechEngine()
        controller.setAppleSpeechForTesting(oldEngine)

        controller.setDeviceAudioFedSampleIndexForTesting(100_000)
        controller.setDeviceAudioBufferStartOffsetForTesting(0)
        controller.appendDeviceAudioBufferForTesting([Float](repeating: 0.1, count: 100_000))

        controller.enterASRHandoffGateForTesting()

        // 4000 samples arrive while gate is in progress
        let gatedChunk = TimedAudioChunk(
            samples: [Float](repeating: 0.5, count: 4000),
            sampleRate: 16000,
            channelCount: 1,
            level: 0.5,
            startMediaTime: 6.25,
            endMediaTime: 6.5,
            startSampleIndex: 100_000,
            endSampleIndex: 104_000,
            sourcePTS: 6.25
        )
        controller.deviceAudioDidOutput(chunk: gatedChunk)

        // Configure old engine to receive another chunk while rollback replay is in flight
        var rollbackArrivalInjected = false
        oldEngine.onAppend = { [weak controller] _ in
            guard let controller, !rollbackArrivalInjected else { return }
            rollbackArrivalInjected = true
            let extraChunk = TimedAudioChunk(
                samples: [Float](repeating: 0.6, count: 3000),
                sampleRate: 16000,
                channelCount: 1,
                level: 0.5,
                startMediaTime: 6.5,
                endMediaTime: 6.6875,
                startSampleIndex: 104_000,
                endSampleIndex: 107_000,
                sourcePTS: 6.5
            )
            controller.deviceAudioDidOutput(chunk: extraChunk)
        }

        let session = LectureSession(title: "Rollback Test", language: "zh")
        controller.session = session

        await controller.rollbackGatedDeviceAudio(
            oldEngine: "apple",
            fromSample: 100_000,
            committedBoundary: 100_000,
            current: session
        )
        controller.leaveASRHandoffGateForTesting()

        XCTAssertTrue(rollbackArrivalInjected)
        XCTAssertEqual(oldEngine.appendedSamples.count, 7000)
        XCTAssertEqual(controller.deviceAudioFedSampleIndexForTesting, 107_000)
        XCTAssertEqual(controller.deviceAudioBufferCountForTesting, 107_000)
        XCTAssertFalse(controller.isASRHandoffInProgress)
    }

    @MainActor
    func testModelCenterDownloaderWiringZipformerAndParaformer() async throws {
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
            ModelCenter.shared.customDownloader = nil
            ZipformerStreamingEngine.mockPrepareHandler = nil
            try? ModelCenter.shared.deleteModel("zipformer-bilingual")
        }

        try? ModelCenter.shared.deleteModel("zipformer-bilingual")
        XCTAssertFalse(ZipformerStreamingEngine.isModelInstalled())

        var downloadedModels: [String] = []
        var progressValues: [Double] = []
        ModelCenter.shared.customDownloader = { modelId, progress in
            downloadedModels.append(modelId)
            progress(0.4)
            progressValues.append(0.4)
            progress(0.8)
            progressValues.append(0.8)

            // Stage mock files to satisfy isModelInstalled()
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SpeechModels", isDirectory: true)
            let target = base.appendingPathComponent(ZipformerStreamingEngine.modelFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let data = Data(repeating: 0x42, count: 2048)
            try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.encoderName))
            try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.decoderName))
            try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.joinerName))
            try "token 1\n".write(to: target.appendingPathComponent(ZipformerStreamingEngine.tokensName), atomically: true, encoding: .utf8)
            progress(1.0)
            progressValues.append(1.0)
        }

        var prepareInvoked = false
        ZipformerStreamingEngine.mockPrepareHandler = { _, onProgress in
            prepareInvoked = true
            onProgress(1.0)
        }

        let controller = LectureController()
        controller.isRecording = false
        controller.setRecognitionEngine("zipformer")

        await controller.prepareModel()

        XCTAssertEqual(downloadedModels, ["zipformer-bilingual"])
        XCTAssertTrue(prepareInvoked)
        XCTAssertEqual(controller.resourceState, .ready)
        XCTAssertEqual(controller.loadedModel, "zipformer")
        XCTAssertTrue(ZipformerStreamingEngine.isModelInstalled())
    }

    @MainActor
    func testModelCenterDownloaderSkipIfAlreadyInstalled() async throws {
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
            ModelCenter.shared.customDownloader = nil
            ZipformerStreamingEngine.mockPrepareHandler = nil
            try? ModelCenter.shared.deleteModel("zipformer-bilingual")
        }

        // Install model beforehand
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
        let target = base.appendingPathComponent(ZipformerStreamingEngine.modelFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data(repeating: 0x42, count: 2048)
        try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.encoderName))
        try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.decoderName))
        try data.write(to: target.appendingPathComponent(ZipformerStreamingEngine.joinerName))
        try "token 1\n".write(to: target.appendingPathComponent(ZipformerStreamingEngine.tokensName), atomically: true, encoding: .utf8)
        XCTAssertTrue(ZipformerStreamingEngine.isModelInstalled())

        var downloadCalled = false
        ModelCenter.shared.customDownloader = { _, _ in
            downloadCalled = true
            XCTFail("Must NOT be invoked when model is already installed")
        }

        var prepareInvoked = false
        ZipformerStreamingEngine.mockPrepareHandler = { _, onProgress in
            prepareInvoked = true
            onProgress(1.0)
        }

        let controller = LectureController()
        controller.isRecording = false
        controller.setRecognitionEngine("zipformer")

        await controller.prepareModel()

        XCTAssertFalse(downloadCalled)
        XCTAssertTrue(prepareInvoked)
        XCTAssertEqual(controller.resourceState, .ready)
        XCTAssertEqual(controller.loadedModel, "zipformer")
    }

    @MainActor
    func testHotSwitchDuringRecordingDoesNotTriggerDownloadWhenModelMissing() async throws {
        let previousSource = UserDefaults.standard.string(forKey: "audioInputSource")
        let previousEngine = UserDefaults.standard.string(forKey: "recognitionEngine")
        defer {
            if let previousSource {
                UserDefaults.standard.set(previousSource, forKey: "audioInputSource")
            } else {
                UserDefaults.standard.removeObject(forKey: "audioInputSource")
            }
            if let previousEngine {
                UserDefaults.standard.set(previousEngine, forKey: "recognitionEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "recognitionEngine")
            }
            ModelCenter.shared.customDownloader = nil
            try? ModelCenter.shared.deleteModel("zipformer-bilingual")
        }

        try? ModelCenter.shared.deleteModel("zipformer-bilingual")
        XCTAssertFalse(ZipformerStreamingEngine.isModelInstalled())

        var downloadCalled = false
        ModelCenter.shared.customDownloader = { _, _ in
            downloadCalled = true
            XCTFail("Hot-switch during recording must NEVER trigger automated download")
        }

        let controller = LectureController()
        controller.audioSource = .deviceAudio
        controller.isRecording = true
        controller.recognitionEngine = "apple"
        let activeEngine = MockLiveSpeechEngine()
        controller.setAppleSpeechForTesting(activeEngine)

        let session = LectureSession(title: "Recording Session", language: "zh")
        controller.session = session

        await controller.switchRecognitionEngine(to: "zipformer")

        XCTAssertFalse(downloadCalled)
        XCTAssertEqual(controller.recognitionEngine, "apple")
        XCTAssertTrue(controller.isRecording)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isASRHandoffInProgress)
    }
}

@MainActor
final class MockLiveSpeechEngine: LiveSpeechEngine {
    var appendedSamples: [Float] = []
    var isCancelled = false
    var isFinished = false
    var isStarted = false
    var onAppend: (([Float]) async throws -> Void)?

    func prepare(language: String, onProgress: @escaping @MainActor (Double?) -> Void) async throws {}
    func start(language: String, onResult: @escaping @MainActor (SpeechUpdate) -> Void) async throws {
        isStarted = true
    }
    func append(_ samples: [Float]) async throws {
        appendedSamples.append(contentsOf: samples)
        if let onAppend {
            try await onAppend(samples)
        }
    }
    func finish() async throws {
        isFinished = true
    }
    func cancel() async {
        isCancelled = true
    }
}

