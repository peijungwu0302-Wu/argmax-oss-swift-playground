import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LectureController: ObservableObject {
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var model = SpeechModel.small.rawValue
    @Published var language = "auto"
    @Published var title = ""
    @Published var status = "先載入模型，再開始錄音"
    @Published var progress: Double?
    @Published var loadedModel: String?
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var isDecoding = false
    @Published var level: Float = 0
    @Published var provisional: [TranscriptLine] = []
    @Published var errorMessage: String?
    @Published var lastSaved: Date?
    @Published var search = ""

    private let engine = WhisperEngine()
    private let recorder = PCMRecorder()
    private var store: SessionStore?
    private var worker: Task<Void, Never>?
    private var meter: Timer?
    private var activePartID: UUID?
    private var lastPreviewSample = 0
    private var observers: [NSObjectProtocol] = []
    private var saveCounter = 0

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
    var canStart: Bool { !isBusy && !isRecording && worker == nil && !(session?.hasPendingAudio ?? false) }
    var settingsLocked: Bool { isBusy || isRecording || session != nil }

    func prepareModel() async {
        guard !isBusy, !isRecording, worker == nil else { return }
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
            if session == nil {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                session = LectureSession(title: cleanTitle.isEmpty ? "課堂 \(Date().formatted(date: .abbreviated, time: .shortened))" : cleanTitle,
                    model: model, language: language)
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
                let enoughNewAudio = part.sampleCount - lastPreviewSample >= 3 * 16000
                if available >= 3 * 16000 && (enoughNewAudio || available >= 26 * 16000) {
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
        defer { isDecoding = false }
        let lines = try await engine.transcribe(file: store.audioURL(current, part), start: part.processedSamples,
            count: count, offset: offset, language: current.language)
        guard session?.id == current.id, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        let decision = WindowDecision.make(lines: lines, samples: count, offset: offset, final: final && count == available)
        provisional = decision.provisional
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
        guard !isBusy, !isRecording, let session else { return }
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
        persist()
    }
    func rename(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session?.title = text; title = text; persist()
    }
    func newLecture() {
        guard !isRecording, !isBusy, worker == nil else { return }
        persist(); reloadHistory()
        session = nil; title = ""; provisional = []; search = ""
        status = "準備新的一堂課"
    }
    func open(_ saved: LectureSession) {
        guard !isRecording, !isBusy, worker == nil else { return }
        session = saved; title = saved.title; model = saved.model; language = saved.language
        provisional = []; search = ""
        status = saved.hasPendingAudio ? "找到尚未完成的錄音，請按補辨識" : "已開啟本機逐字稿，可繼續錄音"
    }
    func export(_ format: TranscriptFormat) -> URL? {
        guard let session, let store else { return nil }
        do { return try store.export(session, format: format) }
        catch { fail("匯出失敗。", error); return nil }
    }
    private func persist() {
        guard let session, let store else { return }
        do { try store.save(session); lastSaved = Date() }
        catch { errorMessage = "自動儲存失敗：\(error.localizedDescription)。請先暫停並檢查剩餘空間。" }
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
