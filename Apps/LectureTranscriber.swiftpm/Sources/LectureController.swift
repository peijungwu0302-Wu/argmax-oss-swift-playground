import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LectureController: ObservableObject {
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var model = SpeechModel.turbo.rawValue
    @Published var language = "mixed"
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
    @Published var isSummarizing = false
    @Published var summaryStatus = ""

    private let engine = WhisperEngine()
    private let recorder = PCMRecorder()
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

    func prepareModel() async {
        guard canManageSessions else { return }
        isBusy = true
        defer { isBusy = false; progress = nil }
        do { try await loadModel(session?.model ?? model) }
        catch { fail("模型載入失敗。請確認網路、儲存空間，再按一次載入。", error) }
    }
    private func loadModel(_ name: String) async throws {
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
                    model: model, language: language, vocabulary: vocabulary)
            }
            guard var current = session else { return }
            let part = AudioPart(fileName: UUID().uuidString + ".pcm", offset: current.duration)
            current.parts.append(part)
            try store.save(current)
            session = current
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
        } catch { fail("無法開始錄音。", error) }
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
        do {
            while isRecording {
                updateAudioCount()
                guard let current = session, let part = current.parts.last else { break }
                let available = part.sampleCount - part.processedSamples
                let enoughNewAudio = part.sampleCount - lastPreviewSample >= 16000
                if available >= 16000 && (enoughNewAudio || available >= 26 * 16000) {
                    lastPreviewSample = part.sampleCount
                    try await decodePart(part.id, final: false)
                } else {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        } catch is CancellationError {
            // Cancellation never marks unfinished audio as confirmed.
        } catch {
            stopCapture()
            fail("辨識暫停，已錄聲音保留在本機，可按「補辨識」。", error)
        }
        isDecoding = false
        worker = nil
        reloadHistory()
    }

    // Keep two seconds of right context, then advance at the last confirmed segment end.
    // The last partial window is always decoded again when paused/stopped.
    private func decodePart(_ id: UUID, final: Bool) async throws {
        guard let store, let current = session, let part = current.parts.first(where: { $0.id == id }) else { return }
        let available = part.sampleCount - part.processedSamples
        guard available > 0 else { return }
        let count = min(26 * 16000, available)
        let offset = part.offset + Double(part.processedSamples) / 16000
        isDecoding = true
        let request = UUID()
        activeDecodeID = request; draftRevision = 0; liveDraft = ""
        let started = Date()
        defer { isDecoding = false; activeDecodeID = nil; liveDraft = "" }
        let lines = try await engine.transcribe(file: store.audioURL(current, part), start: part.processedSamples,
            count: count, offset: offset, language: current.language,
            vocabulary: current.vocabulary ?? "", context: current.lines.suffix(2).map(\.text).joined(separator: " "), final: final) { [weak self] text, revision in
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
        let decision = WindowDecision.make(lines: lines, samples: count, offset: offset, final: final && count == available,
                                           previous: previousHypothesis)
        provisional = decision.provisional
        previousHypothesis = decision.provisional
        if decision.consumed > 0 {
            // Audio count may have increased while decoding; mutate the live session.
            session?.lines.append(contentsOf: decision.confirmed)
            session?.parts[index].processedSamples += decision.consumed
            guard let updated = session else { return }
            try store.save(updated)
            lastSaved = Date()
        }
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
            status = "補辨識完成，已儲存"
            reloadHistory()
        } catch { fail("補辨識未完成，原始聲音仍保留在本機。", error) }
    }

    private func finishPending() async throws {
        while let part = session?.parts.first(where: { $0.processedSamples < $0.sampleCount }) {
            try await decodePart(part.id, final: true)
        }
        provisional = []
        liveDraft = ""; previousHypothesis = []
        persist()
    }

    func interrupt(_ reason: String) {
        guard isRecording else { return }
        stopCapture()
        // Do not wait for ML when the OS is about to suspend the app.
        status = reason + "。返回後可補辨識並繼續。"
        errorMessage = status
    }

    func backgrounded() { interrupt("App 已進入背景，錄音已暫停") }
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
        translatedDraft = ""; summaryStatus = ""
        liveDraft = ""; previousHypothesis = []; lastDecodeSeconds = nil; draftAudioEnd = 0; lastSaved = nil
        status = "準備新的一堂課"
    }
    func open(_ saved: LectureSession) {
        guard canManageSessions else { return }
        session = saved; title = saved.title; model = saved.model; language = saved.language
        vocabulary = saved.vocabulary ?? ""
        provisional = []; search = ""
        translatedDraft = ""; summaryStatus = ""
        liveDraft = ""; previousHypothesis = []; lastDecodeSeconds = nil; draftAudioEnd = saved.duration
        status = saved.hasPendingAudio ? "找到尚未完成的錄音，請按補辨識" : "已開啟本機逐字稿，可繼續錄音"
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
            await engine.unload(); loadedModel = nil
            let result = try await SmartNotes.generate(current) { [weak self] value in
                Task { @MainActor in self?.summaryStatus = value }
            }
            guard session?.id == current.id, session?.sourceText == current.sourceText else { return }
            session?.minutes = result.text; session?.minutesKind = result.kind
            session?.minutesSource = current.sourceText
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
