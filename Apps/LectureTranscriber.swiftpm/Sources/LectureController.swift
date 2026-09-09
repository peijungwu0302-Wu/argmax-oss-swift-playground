import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LectureController: ObservableObject {
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var model = SpeechModel.turbo.rawValue
    @Published var recognitionEngine = "apple"
    @Published var language = "zh"
    @Published var vocabulary = ""
    @Published var title = ""
    @Published var status = "先載入模型，再開始錄音"
    @Published var progress: Double?
    @Published var loadedModel: String?
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var isDecoding = false
    @Published var level: Float = 0
    @Published var provisional: [TranscriptLine] = []
    @Published var liveDraft = ""
    @Published var lastDecodeSeconds: Double?
    @Published var draftAudioEnd: Double = 0
    @Published var errorMessage: String?
    @Published var lastSaved: Date?
    @Published var search = ""
    @Published var translationEnabled = false
    @Published var translationStatus = "開啟後，英語內容會分段翻成繁體中文"
    @Published var translatedDraft = ""
    @Published var translationDraftSource = ""
    @Published var translationGeneration = UUID()
    @Published var translationDraftKey: DraftTranslationKey?
    @Published var recordingQuality = RecordingQuality(rawValue: UserDefaults.standard.string(forKey: "recordingQuality") ?? "compact") ?? .compact
    @Published var liveDraftStart: Double = 0
    @Published private(set) var pendingAppleLanguage: String?
    @Published var isSummarizing = false
    @Published var summaryStatus = ""

    @Published var notesPrompt = UserDefaults.standard.string(forKey: "notesPrompt") ?? "以繁體中文整理重點、決議、待辦；保留英文術語和來源時間戳。"
    @Published var translationSource = "en"
    var supportsBackgroundAudio: Bool { (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true }
    var backgroundDescription: String { supportsBackgroundAudio ? "私人安裝版支援背景收音；系統中斷或資源限制仍可能暫停，回到畫面可補辨識。" : "Playground 版請保持字幕視窗可見；測試背景錄音請使用 IPA。" }
    func audioSize(_ lecture: LectureSession) -> String {
        ByteCountFormatter.string(fromByteCount: store?.audioBytes(lecture) ?? 0, countStyle: .file)
    }
    func audioURL(_ lecture: LectureSession, _ part: AudioPart) -> URL? { store?.audioURL(lecture, part) }
    func saveNotesPrompt() { notesPrompt = String(notesPrompt.prefix(800)); UserDefaults.standard.set(notesPrompt, forKey: "notesPrompt") }
    private let engine = WhisperEngine()
    private let senseVoice = SenseVoiceEngine()
    private let recorder = PCMRecorder()
    private var appleSpeech: (any LiveSpeechEngine)?
    private var appleCursor = 0
    private var appleRangeStart = 0
    private var store: SessionStore?
    private var worker: Task<Void, Never>?
    private var meter: Timer?
    private var activePartID: UUID?
    private var lastPreviewSample = 0
    private var observers: [NSObjectProtocol] = []
    private var saveCounter = 0
    private var activeDecodeID: UUID?
    private var draftRevision = 0
    private var previousHypothesis: [TranscriptLine] = []
    private var appleCaptions = AppleCaptionState()

    init() {
        do {
            let store = try SessionStore()
            self.store = store
            history = try store.loadAll()
        } catch { errorMessage = "無法讀取本機資料：\(error.localizedDescription)" }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.interrupt("來電或系統音訊中斷，錄音已暫停") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.interrupt("輸入裝置已拔除，錄音已暫停") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupt("音訊服務已重設，錄音已暫停") }
        })
    }

    var duration: Double { session?.duration ?? 0 }
    var pendingSeconds: Double {
        session?.parts.reduce(0) { $0 + Double(max(0, $1.sampleCount - $1.processedSamples)) / 16000 } ?? 0
    }
    var canStart: Bool { !isBusy && !isSummarizing && !isRecording && worker == nil && !(session?.hasPendingAudio ?? false) }
    var settingsLocked: Bool { isBusy || isSummarizing || isRecording || session != nil }
    var canManageSessions: Bool { !isRecording && !isBusy && !isSummarizing && worker == nil }
    var displayedDraft: String { liveDraft.isEmpty ? provisional.map(\.text).joined(separator: " ") : liveDraft }
    var draftBehindSeconds: Double { max(0, duration - draftAudioEnd) }
    var usesAppleSpeech: Bool { (session?.recognitionEngine ?? recognitionEngine) == "apple" }
    var usesSenseVoice: Bool { (session?.recognitionEngine ?? recognitionEngine) == "sensevoice" }
    var usesWhisper: Bool { !usesAppleSpeech && !usesSenseVoice }
    var draftStart: Double { liveDraft.isEmpty ? (provisional.first?.start ?? duration) : liveDraftStart }
    var caption: String { CaptionText.screen(displayedDraft.isEmpty ? (session?.lines.last?.text ?? "") : displayedDraft) }
    var draftTranslationKey: DraftTranslationKey? {
        guard let session, !displayedDraft.isEmpty else { return nil }
        return DraftTranslationKey(sessionID: session.id, generation: translationGeneration,
                                   startSample: Int((draftStart * 16000).rounded()), source: displayedDraft)
    }
    var validTranslatedDraft: String {
        guard let key = translationDraftKey, let current = draftTranslationKey, key.accepts(current) else { return "" }
        return translatedDraft
    }
    var translationCaption: String {
        if !displayedDraft.isEmpty {
            if !validTranslatedDraft.isEmpty { return CaptionText.screen(validTranslatedDraft) }
            if translationDraftKey?.sessionID == session?.id && translationDraftKey?.generation == translationGeneration && !translatedDraft.isEmpty {
                return "更新中 · 上次翻譯\n" + CaptionText.screen(translatedDraft)
            }
        }
        guard let current = session, let line = current.lines.last else { return "" }
        return CaptionText.screen(current.translation(for: line)?.text ?? "")
    }
    func setTranslationSource(_ value: String) {
        guard value == "en" || value == "ja", value != translationSource else { return }
        translationSource = value; session?.translationSource = value; session?.translations = []
        restartTranslation(); persist()
    }
    func restartTranslation() {
        translatedDraft = ""; translationDraftSource = ""; translationDraftKey = nil
        translationGeneration = UUID()
    }
    func setRecordingQuality(_ value: RecordingQuality) {
        guard canManageSessions else { return }
        recordingQuality = value
        UserDefaults.standard.set(value.rawValue, forKey: "recordingQuality")
    }
    func setLanguage(_ value: String) {
        guard canManageSessions else { return }
        language = value; session?.language = value; loadedModel = nil; restartTranslation(); persist()
    }
    func selectAppleLanguage(_ value: String) {
        guard usesAppleSpeech, value == "zh" || value == "en", !isBusy,
              !isSummarizing, pendingAppleLanguage == nil else { return }
        guard isRecording else { setLanguage(value); return }
        guard RecognitionLanguage.primary(language) != value,
              let id = activePartID, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        updateAudioCount()
        guard let part = session?.parts[index] else { return }
        // Fix the boundary at the button press. Capture continues into the same
        // file while the old analyzer drains and the next language initializes.
        let boundary = max(max(appleCursor, part.sampleCount), appleRangeStart + 1)
        var changes = part.languageChanges ?? [AudioLanguageChange(sample: 0, language: language)]
        changes.removeAll { $0.sample >= boundary }
        changes.append(AudioLanguageChange(sample: boundary, language: value))
        session?.parts[index].languageChanges = changes
        session?.language = value
        pendingAppleLanguage = value
        status = "正在切換為\(value == "en" ? "英文" : "中文")；錄音持續保存，字幕稍後接續…"
        persist()
    }
    func setRecognitionEngine(_ value: String) {
        guard canManageSessions else { return }
        recognitionEngine = value; session?.recognitionEngine = value; loadedModel = nil
        restartTranslation()
        persist()
    }

    func prepareModel() async {
        guard canManageSessions else { return }
        isBusy = true
        defer { isBusy = false; progress = nil }
        do { try await loadModel(session?.model ?? model) }
        catch { fail("模型載入失敗。請確認網路、儲存空間，再按一次載入。", error) }
    }
    private func loadModel(_ name: String) async throws {
        if usesAppleSpeech {
            guard #available(iOS 26.0, *) else { throw LectureError.message("Apple 即時引擎需要 iPadOS 26；請在錄音設定改用 WhisperKit。") }
            status = "正在準備 Apple 語音模型，首次需下載語言資源…"
            await engine.unload(); await senseVoice.unload()
            if appleSpeech == nil { appleSpeech = AppleSpeechEngine() }
            try await appleSpeech?.prepare(language: session?.language ?? language)
            loadedModel = "apple"; status = "Apple 即時語音已就緒"; progress = nil
            return
        }
        await appleSpeech?.cancel(); appleSpeech = nil
        if usesSenseVoice {
            await engine.unload()
            try await senseVoice.load(language: session?.language ?? language) { [weak self] text, fraction in
                Task { @MainActor in
                    guard let self, self.isBusy else { return }
                    self.status = text; self.progress = fraction
                }
            }
            loadedModel = "sensevoice"; status = "SenseVoice 已就緒 · 中英混說實驗版"; progress = nil
            return
        }
        await senseVoice.unload()
        status = "正在載入模型…"
        try await engine.load(name) { [weak self] text, fraction in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                self.status = text; self.progress = fraction
            }
        }
        loadedModel = name; status = "模型已就緒"; progress = nil
    }

    func start() async {
        guard canStart, let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else {
                throw LectureError.message("麥克風未獲授權。請到 iPad 設定允許此 App 使用麥克風，再返回重試。")
            }
            try await loadModel(session?.model ?? model)
            guard UIApplication.shared.applicationState == .active else {
                throw LectureError.message("模型已就緒。請回到 App，再按開始錄音。")
            }
            if session == nil {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                session = LectureSession(title: cleanTitle.isEmpty ? "課堂 \(Date().formatted(date: .abbreviated, time: .shortened))" : cleanTitle,
                    model: model, language: language, vocabulary: vocabulary, recognitionEngine: recognitionEngine)
            }
            guard var current = session else { return }
            let part = AudioPart(fileName: UUID().uuidString + ".pcm16", offset: current.duration,
                languageChanges: usesAppleSpeech ? [AudioLanguageChange(sample: 0, language: current.language)] : nil,
                recordingQuality: recordingQuality)
            current.parts.append(part)
            try store.save(current)
            session = current
            if usesAppleSpeech { try await startApple(part, current: current) }
            do { try recorder.start(at: store.audioURL(current, part)) }
            catch {
                // A failed start may still have created a recoverable empty PCM file.
                session?.parts.removeLast()
                if let remaining = session { try? store.save(remaining) }
                throw error
            }
            activePartID = part.id
            lastPreviewSample = 0
            previousHypothesis = []; liveDraft = ""; draftAudioEnd = part.offset
            isRecording = true; status = "正在錄音 · 聲音只保存在本機"
            UIApplication.shared.isIdleTimerDisabled = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            worker = Task { [weak self] in await self?.streamLoop() }
        } catch { await appleSpeech?.cancel(); fail("無法開始錄音。", error) }
    }

    private func tick() {
        guard isRecording else { return }
        updateAudioCount()
        saveCounter += 1
        if saveCounter >= 20 { saveCounter = 0; persist() }
        if let problem = recorder.snapshot().error { interrupt(problem) }
    }
    private func updateAudioCount() {
        guard let id = activePartID, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = recorder.snapshot()
        session?.parts[index].sampleCount = snapshot.samples
        level = snapshot.level
    }

    private func streamLoop() async {
        defer { pendingAppleLanguage = nil }
        do {
            if usesAppleSpeech {
                try await streamApple()
            } else {
            while isRecording {
                updateAudioCount()
                guard let current = session, let part = current.parts.last else { break }
                let available = part.sampleCount - part.processedSamples
                let enoughNewAudio = part.sampleCount - lastPreviewSample >= 16000
                if available >= (usesSenseVoice ? 32000 : 16000) && (enoughNewAudio || available >= 26 * 16000) {
                    lastPreviewSample = part.sampleCount
                    try await decodePart(part.id, final: false)
                } else {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            }
        } catch is CancellationError {
            // Cancellation never marks unfinished audio as confirmed.
        } catch {
            stopCapture()
            await appleSpeech?.cancel()
            fail("辨識暫停，已錄聲音保留在本機，可按「補辨識」。", error)
        }
        isDecoding = false
        worker = nil
        reloadHistory()
    }

    // Whisper: confirm agreed words or a pause; retain unfinished audio for another pass.
    private func decodePart(_ id: UUID, final: Bool) async throws {
        if usesSenseVoice { try await decodeSenseVoice(id, final: final); return }
        guard let store, let current = session, let part = current.parts.first(where: { $0.id == id }) else { return }
        let available = part.sampleCount - part.processedSamples
        guard available > 0 else { return }
        let hasWordTiming = await engine.supportsWordTiming()
        let overlap = hasWordTiming ? min(4000, part.processedSamples) : 0
        let count = min(26 * 16000, available + overlap)
        let offset = part.offset + Double(part.processedSamples - overlap) / 16000
        let cursorTime = part.offset + Double(part.processedSamples) / 16000
        isDecoding = true
        let request = UUID()
        activeDecodeID = request; draftRevision = 0
        liveDraftStart = cursorTime
        let started = Date()
        defer { isDecoding = false; activeDecodeID = nil; liveDraft = "" }
        let decoded = try await engine.transcribe(file: store.audioURL(current, part), start: part.processedSamples - overlap,
            count: count, offset: offset, language: current.language,
            vocabulary: current.vocabulary ?? "", final: final) { [weak self] text, revision in
                Task { @MainActor in
                    guard let self, self.activeDecodeID == request, self.session?.id == current.id,
                          revision > self.draftRevision else { return }
                    self.draftRevision = revision; self.liveDraft = text
                    self.draftAudioEnd = offset + Double(count) / 16000
                }
            }
        guard session?.id == current.id, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        lastDecodeSeconds = Date().timeIntervalSince(started)
        draftAudioEnd = offset + Double(count) / 16000
        let lines = overlap > 0 ? CaptionText.after(decoded.lines, time: cursorTime) : decoded.lines
        let decision = WindowDecision.make(lines: lines, samples: count, offset: offset, final: final && count - overlap == available,
                                           previous: previousHypothesis, utteranceEnded: decoded.endsWithPause)
        provisional = decision.provisional
        previousHypothesis = decision.provisional
        if decision.consumed > overlap {
            // Audio count may have increased while decoding; mutate the live session.
            session?.appendConfirmed(decision.confirmed)
            session?.parts[index].processedSamples += decision.consumed - overlap
            guard let updated = session else { return }
            try store.save(updated)
            lastSaved = Date()
        }
    }

    private func decodeSenseVoice(_ id: UUID, final: Bool) async throws {
        guard let store, let current = session, let part = current.parts.first(where: { $0.id == id }) else { return }
        let count = min(SenseVoiceWindow.maximumSamples, part.sampleCount - part.processedSamples)
        guard count > 0 else { return }
        isDecoding = true
        defer { isDecoding = false }
        let file = store.audioURL(current, part)
        let samples = try await Task.detached(priority: .userInitiated) {
            try PCMRecorder.read(file, from: part.processedSamples, count: count)
        }.value
        let window = SenseVoiceWindow.choose(samples, final: final)
        let started = Date()
        let text = window.hasSpeech ? try await senseVoice.transcribe(Array(samples.prefix(window.count))) : ""
        guard session?.id == current.id, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        lastDecodeSeconds = Date().timeIntervalSince(started)
        let start = part.offset + Double(part.processedSamples) / 16000
        let end = start + Double(window.count) / 16000
        draftAudioEnd = end; liveDraft = ""
        let lines = text.isEmpty ? [] : [TranscriptLine(start: start, end: end, text: text)]
        if window.commit {
            session?.appendConfirmed(lines)
            session?.parts[index].processedSamples += window.count
            provisional = []; previousHypothesis = []
            if let updated = session { try store.save(updated); lastSaved = Date() }
        } else { provisional = lines }
    }

    private func stopCapture() {
        guard isRecording else { return }
        recorder.stop()
        updateAudioCount()
        isRecording = false; level = 0
        meter?.invalidate(); meter = nil
        UIApplication.shared.isIdleTimerDisabled = false
        persist()
    }

    func pause() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        stopCapture()
        status = "正在補完最後一段…"
        await worker?.value
        worker = nil
        do {
            try await finishPending()
            await archiveCompletedAudio()
            status = "已暫停並儲存，可繼續同一堂課"
        } catch { fail("最後一段尚未完成；音訊已保留，請按「補辨識」。", error) }
        isBusy = false
        reloadHistory()
    }

    func recover() async {
        guard !isBusy, !isSummarizing, !isRecording, let session else { return }
        isBusy = true
        await worker?.value; worker = nil
        defer { isBusy = false; progress = nil }
        do {
            try await loadModel(session.model)
            status = "正在補辨識已保存的聲音…"
            try await finishPending()
            await archiveCompletedAudio()
            status = "補辨識完成，已儲存"
            reloadHistory()
        } catch { fail("補辨識未完成，原始聲音仍保留在本機。", error) }
    }

    private func finishPending() async throws {
        while let part = session?.parts.first(where: { $0.processedSamples < $0.sampleCount }) {
            if usesAppleSpeech, let current = session {
                try await startApple(part, current: current)
                try await feedApple(part.id)
                try await completeApple(part.id)
            } else { try await decodePart(part.id, final: true) }
        }
        provisional = []
        liveDraft = ""; previousHypothesis = []
        persist()
    }

    private func archiveCompletedAudio() async {
        guard let store, let current = session, !isRecording else { return }
        for part in current.parts where part.processedSamples == part.sampleCount && part.sampleCount > 0 {
            guard AudioStorage.bytesPerSample(fileName: part.fileName) != nil,
                  let bitRate = part.recordingQuality?.bitRate else { continue }
            let original = store.audioURL(current, part)
            status = "正在壓縮保存錄音，請保持 App 開啟…"
            do {
                let archived = try await Task.detached(priority: .utility) {
                    try PCMRecorder.archive(original, samples: part.sampleCount, bitRate: bitRate)
                }.value
                guard var updated = session, updated.id == current.id,
                      let index = updated.parts.firstIndex(where: { $0.id == part.id }) else { return }
                updated.parts[index].fileName = archived.lastPathComponent
                try store.save(updated) // A failed metadata commit must leave the PCM untouched.
                session = updated; lastSaved = Date()
                try FileManager.default.removeItem(at: original)
            } catch {
                errorMessage = "錄音已保存，但壓縮尚未完成：\(error.localizedDescription)。原始聲音不會因壓縮失敗被刪除。"
            }
        }
    }

    func interrupt(_ reason: String) {
        guard isRecording else { return }
        stopCapture()
        // Do not wait for ML when the OS is about to suspend the app.
        status = reason + "。返回後可補辨識並繼續。"
        errorMessage = status
    }

    func backgrounded() {
        if supportsBackgroundAudio && isRecording {
            updateAudioCount(); persist()
            status = "背景錄音中；返回 App 後檢查字幕進度"
        } else { interrupt("App 已進入背景，錄音已暫停") }
    }
    func foregrounded() { if translationEnabled { restartTranslation() } }
    func bookmark(_ note: String) {
        guard session != nil else { return }
        updateAudioCount()
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        session?.bookmarks.append(Bookmark(seconds: duration, note: value.isEmpty ? "重點" : value))
        persist()
    }
    func updateLine(_ id: UUID, text: String) {
        guard let index = session?.lines.firstIndex(where: { $0.id == id }) else { return }
        session?.lines[index].text = text
        session?.lines[index].words = nil
        session?.translations?.removeAll { $0.id == id }
        persist()
    }
    func rename(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session?.title = text; title = text; persist()
    }
    func newLecture() {
        guard canManageSessions else { return }
        persist(); reloadHistory()
        session = nil; title = ""; provisional = []; search = ""
        restartTranslation()
        translatedDraft = ""; summaryStatus = ""
        liveDraft = ""; previousHypothesis = []; lastDecodeSeconds = nil; draftAudioEnd = 0; lastSaved = nil
        status = "準備新的一堂課"
    }
    func open(_ saved: LectureSession) {
        guard canManageSessions else { return }
        session = saved; title = saved.title; model = saved.model; language = saved.language
        translationSource = saved.translationSource ?? "en"
        restartTranslation()
        recognitionEngine = saved.recognitionEngine ?? "whisper"
        vocabulary = saved.vocabulary ?? ""
        provisional = []; search = ""
        translatedDraft = ""; summaryStatus = ""
        liveDraft = ""; previousHypothesis = []; lastDecodeSeconds = nil; draftAudioEnd = saved.duration
        status = saved.hasPendingAudio ? "找到尚未完成的錄音，請按補辨識" : "已開啟本機逐字稿，可繼續錄音"
    }
    func importAudio(_ source: URL) async {
        guard canManageSessions, let store else { return }
        persist()
        isBusy = true; status = "正在匯入並轉成辨識音訊，請保持 App 開啟…"
        var imported = LectureSession(title: source.deletingPathExtension().lastPathComponent,
            model: model, language: language, vocabulary: vocabulary, recognitionEngine: recognitionEngine)
        let part = AudioPart(fileName: UUID().uuidString + ".pcm16", offset: 0, recordingQuality: recordingQuality)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() }; isBusy = false }
        do {
            try FileManager.default.createDirectory(at: store.folder(imported.id), withIntermediateDirectories: true)
            let destination = store.audioURL(imported, part)
            let count = try await Task.detached(priority: .userInitiated) { try StoredAudio.importAudio(source, to: destination) }.value
            var complete = part; complete.sampleCount = count
            imported.parts = [complete]; try store.save(imported)
            isBusy = false; open(imported); reloadHistory()
            status = "已匯入音訊；按「補辨識」開始，原本的檔案不受影響"
        } catch {
            try? store.delete(imported.id)
            fail("無法匯入音訊，請選擇可播放的 WAV、M4A 或 MP3。", error)
        }
    }
    func export(_ format: TranscriptFormat) -> URL? {
        guard let session, let store else { return nil }
        do { return try store.export(session, format: format) }
        catch { fail("匯出失敗。", error); return nil }
    }
    func deleteLecture(_ id: UUID) {
        guard canManageSessions, let store else { return }
        do {
            try store.delete(id)
            if session?.id == id {
                // Do not call newLecture(): its persistence would recreate the deleted folder.
                session = nil; title = ""; provisional = []; liveDraft = ""; search = ""
                translatedDraft = ""; summaryStatus = ""
                previousHypothesis = []; activeDecodeID = nil; lastSaved = nil
                lastDecodeSeconds = nil; draftAudioEnd = 0
                status = "錄音與逐字稿已刪除"
            }
            reloadHistory()
        } catch { fail("刪除失敗，請重試。", error) }
    }
    private func persist() {
        guard let session, let store else { return }
        do { try store.save(session); lastSaved = Date() }
        catch { errorMessage = "自動儲存失敗：\(error.localizedDescription)。請先暫停並檢查剩餘空間。" }
    }
    private func startApple(_ part: AudioPart, current: LectureSession) async throws {
        guard let appleSpeech else { throw LectureError.message("請先載入 Apple 語音模型。") }
        appleCursor = part.processedSamples
        appleRangeStart = part.processedSamples
        let from = part.processedSamples
        let offset = part.offset + Double(from) / 16000
        let generation = UUID(); activeDecodeID = generation
        appleCaptions = AppleCaptionState()
        liveDraft = ""; provisional = []; restartTranslation()
        let selectedLanguage = part.language(at: from, fallback: current.language)
        try await appleSpeech.start(language: selectedLanguage) { [weak self] result in
            guard let self, self.activeDecodeID == generation, self.session?.id == current.id,
                  let index = self.session?.parts.firstIndex(where: { $0.id == part.id }),
                  result.start.isFinite, result.end.isFinite else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.draftAudioEnd = max(self.draftAudioEnd, offset + result.end)
            let line = TranscriptLine(start: result.start, end: result.end, text: text)
            let confirmed = self.appleCaptions.receive(line, final: result.isFinal)
            if result.isFinal {
                if let confirmed {
                    self.session?.lines.append(TranscriptLine(start: offset + confirmed.start, end: offset + confirmed.end, text: confirmed.text))
                }
                let through = result.finalizedThrough.isFinite ? result.finalizedThrough : result.end
                let durable = from + Int(max(0, through) * 16000)
                let count = self.session?.parts[index].sampleCount ?? 0
                let previous = self.session?.parts[index].processedSamples ?? 0
                self.session?.parts[index].processedSamples = min(count, max(previous, durable))
                self.persist()
            }
            self.liveDraftStart = offset + (self.appleCaptions.draft?.start ?? result.end)
            self.liveDraft = self.appleCaptions.draft?.text ?? ""
            self.provisional = []
        }
        language = selectedLanguage
    }
    private func feedApple(_ partID: UUID) async throws {
        guard let store, let appleSpeech else { return }
        while let current = session, let part = current.parts.first(where: { $0.id == partID }), appleCursor < part.sampleCount {
            let end = min(part.sampleCount, part.nextLanguageBoundary(after: appleRangeStart) ?? part.sampleCount)
            guard appleCursor < end else { break }
            let count = min(4000, end - appleCursor)
            let samples = try PCMRecorder.read(store.audioURL(current, part), from: appleCursor, count: count)
            try await appleSpeech.append(samples)
            appleCursor += count
        }
    }
    private func completeApple(_ partID: UUID) async throws {
        try await appleSpeech?.finish()
        if let index = session?.parts.firstIndex(where: { $0.id == partID }) {
            session?.parts[index].processedSamples = appleCursor
        }
        activeDecodeID = nil; liveDraft = ""; provisional = []; persist()
    }
    private func streamApple() async throws {
        guard let partID = activePartID else { return }
        while true {
            updateAudioCount()
            try await feedApple(partID)
            guard let current = session, let part = current.parts.first(where: { $0.id == partID }) else { return }
            if let boundary = part.nextLanguageBoundary(after: appleRangeStart), appleCursor >= boundary {
                try await completeApple(partID)
                guard let updated = session, let remaining = updated.parts.first(where: { $0.id == partID }) else { return }
                if !isRecording && remaining.sampleCount <= appleCursor { return }
                try await startApple(remaining, current: updated)
                pendingAppleLanguage = nil; loadedModel = "apple"
                status = "正在錄音 · Apple \(RecognitionLanguage.primary(language) == "en" ? "英文" : "中文")"
                continue
            }
            if !isRecording {
                try await completeApple(partID)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    func saveTranslation(sessionID: UUID, line: TranscriptLine, text: String) {
        guard session?.id == sessionID, session?.lines.contains(line) == true else { return }
        var values = session?.translations ?? []
        values.removeAll { $0.id == line.id }
        values.append(TranslatedLine(id: line.id, source: line.text, text: text))
        session?.translations = values
        persist()
    }
    func generateMinutes() async {
        guard canManageSessions, let current = session, !current.lines.isEmpty, !current.hasPendingAudio else { return }
        isSummarizing = true; summaryStatus = "正在整理…"
        defer { isSummarizing = false }
        do {
            // Recording and decoding have finished. Release our Core ML references
            // before asking the system language model to process the lecture.
            await engine.unload(); await senseVoice.unload(); loadedModel = nil
            let result = try await SmartNotes.generate(current, prompt: notesPrompt) { [weak self] value in
                Task { @MainActor in self?.summaryStatus = value }
            }
            guard session?.id == current.id, session?.sourceText == current.sourceText else { return }
            session?.minutes = result.text; session?.minutesKind = result.kind
            session?.minutesSource = current.sourceText
            session?.minutesPrompt = notesPrompt
            summaryStatus = result.kind; persist(); reloadHistory()
        } catch { summaryStatus = "整理未完成"; fail("無法完成 AI 整理；原始逐字稿已保存。可改用原文整理。", error) }
    }
    func makeOutline() {
        guard canManageSessions, let current = session, !current.lines.isEmpty else { return }
        session?.minutes = MeetingNotes.outline(current)
        session?.minutesKind = "原文整理（未使用 AI）"; session?.minutesSource = current.sourceText
        persist(); reloadHistory()
    }
    func exportNotes(translation: Bool) -> URL? {
        guard let current = session, let store else { return nil }
        let body: String
        if translation {
            body = "# \(current.title) · 中文翻譯\n\n僅包含已完成翻譯的段落。請對照原文核對專有名詞與數字。\n\n" + current.lines.compactMap { line in
                current.translation(for: line).map { "[\(TranscriptExport.clock(line.start))] \($0.text)" }
            }.joined(separator: "\n\n")
        } else {
            guard let minutes = current.minutes else { return nil }
            body = (current.minutesAreCurrent ? "" : "注意：逐字稿已有更新，以下是先前整理的版本。\n\n") + minutes
        }
        let url = store.folder(current.id).appendingPathComponent(translation ? "中文翻譯.md" : "會議紀錄.md")
        do { try body.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { fail("匯出失敗。", error); return nil }
    }
    func reloadHistory() {
        do { if let store { history = try store.loadAll() } }
        catch { errorMessage = "讀取歷史紀錄失敗：\(error.localizedDescription)" }
    }
    private func fail(_ context: String, _ error: Error) {
        status = context
        errorMessage = context + "\n\n" + error.localizedDescription
    }
}
