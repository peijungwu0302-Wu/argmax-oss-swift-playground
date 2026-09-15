import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LectureController: ObservableObject {
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var model = SpeechModel.turbo.rawValue
    @Published var recognitionEngine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
    @Published var language = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "zh"
    @Published var vocabulary = ""
    @Published var title = ""
    @Published var status = "先載入模型，再開始錄音"
    @Published var progress: Double?
    @Published var loadedModel: String?
    @Published var isRecording = false
    @Published private(set) var isInForeground = true
    @Published var isBusy = false
    @Published var isDecoding = false
    @Published var level: Float = 0
    @Published var provisional: [TranscriptLine] = []
    @Published var liveDraft = "" {
        didSet {
            CaptionFeed.shared.update(original: caption, translation: validTranslatedDraft)
            if !liveDraft.isEmpty {
                captionRevisionCounter += 1
                print("CaptionLatency speech_partial=\(Date().timeIntervalSince1970) revision=\(captionRevisionCounter)")
                LiveActivityCoordinator.shared.updatePartial(
                    original: caption,
                    translation: validTranslatedDraft,
                    revision: captionRevisionCounter
                )
            }
        }
    }
    @Published var lastDecodeSeconds: Double?
    @Published var draftAudioEnd: Double = 0
    @Published var errorMessage: String?
    @Published var lastSaved: Date?
    @Published var search = ""
    @Published var translationEnabled = UserDefaults.standard.object(forKey: "translationEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: "translationEnabled") }
    }
    @Published var translationStatus = "開啟後，英語內容會分段翻成繁體中文"
    @Published var translatedDraft = "" {
        didSet {
            CaptionFeed.shared.update(original: caption, translation: validTranslatedDraft)
        }
    }
    @Published var translationDraftSource = ""
    @Published var translationGeneration = UUID()
    @Published var translationDraftKey: DraftTranslationKey?
    @Published var translationSpeedPreset: TranslationSpeedPreset = {
        if let raw = UserDefaults.standard.string(forKey: "translationSpeedPreset"),
           let preset = TranslationSpeedPreset(rawValue: raw) {
            return preset
        }
        return .fast
    }() {
        didSet {
            UserDefaults.standard.set(translationSpeedPreset.rawValue, forKey: "translationSpeedPreset")
        }
    }
    @Published var translationCustomInterval: TimeInterval = UserDefaults.standard.double(forKey: "translationCustomInterval") == 0 ? 0.4 : UserDefaults.standard.double(forKey: "translationCustomInterval") {
        didSet {
            UserDefaults.standard.set(translationCustomInterval, forKey: "translationCustomInterval")
        }
    }
    var translationInterval: TimeInterval {
        translationSpeedPreset == .custom ? translationCustomInterval : translationSpeedPreset.defaultInterval
    }
    @Published var translationProvider: String = UserDefaults.standard.string(forKey: "translationProvider") ?? "apple" {
        didSet { UserDefaults.standard.set(translationProvider, forKey: "translationProvider") }
    }
    @Published var isLowLatencyTranslation: Bool = true
    @Published var resourceState: ResourceState = .notDownloaded
    @Published var recordingQuality = RecordingQuality(rawValue: UserDefaults.standard.string(forKey: "recordingQuality") ?? "compact") ?? .compact
    @Published var liveDraftStart: Double = 0
    @Published private(set) var pendingAppleLanguage: String?
    @Published var isSummarizing = false
    @Published var summaryStatus = ""
    @Published private(set) var senseVoiceInputStatus = ""
    @Published var pipActive = false
    @Published var pipEnabled = false
    @Published private(set) var lastASRSwitchBoundary: ASRSwitchBoundary?
    var canProcessLiveAudio: Bool { isInForeground || pipActive || (supportsBackgroundAudio && isRecording) }

    @Published var audioSource: AudioInputSource = {
        if let raw = UserDefaults.standard.string(forKey: "audioInputSource"),
           let source = AudioInputSource(rawValue: raw) {
            return source
        }
        return .microphone
    }() {
        didSet {
            UserDefaults.standard.set(audioSource.rawValue, forKey: "audioInputSource")
        }
    }

    @Published var sessionStorageMode: SessionStorageMode = {
        if let raw = UserDefaults.standard.string(forKey: "sessionStorageMode"),
           let mode = SessionStorageMode(rawValue: raw) {
            return mode
        }
        return .liveOnly
    }() {
        didSet {
            UserDefaults.standard.set(sessionStorageMode.rawValue, forKey: "sessionStorageMode")
        }
    }
    @Published var translationTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hant" {
        didSet { UserDefaults.standard.set(translationTarget, forKey: "translationTarget") }
    }
    @Published var translationStrategy: TranslationQualityStrategy = TranslationQualityStrategy(
        rawValue: UserDefaults.standard.string(forKey: "translationStrategy") ?? ""
    ) ?? .automatic {
        didSet { UserDefaults.standard.set(translationStrategy.rawValue, forKey: "translationStrategy") }
    }
    @Published var deviceAudioSavePreference: DeviceAudioSavePreference = DeviceAudioSavePreference(
        rawValue: UserDefaults.standard.string(forKey: "deviceAudioSavePreference") ?? ""
    ) ?? .defaultValue {
        didSet { UserDefaults.standard.set(deviceAudioSavePreference.rawValue, forKey: "deviceAudioSavePreference") }
    }
    @Published private(set) var deviceAudioAwaitingSaveDecision = false

    @Published var deviceAudioDuration: Double = 0
    private var deviceAudioBuffer: [Float] = []
    private var deviceAudioBufferLock = NSLock()
    private var deviceAudioBufferStartOffset = 0
    private var deviceAudioProcessedSamples = 0

    @Published var notesPrompt = UserDefaults.standard.string(forKey: "notesPrompt") ?? "以繁體中文整理重點、決議、待辦；保留英文術語和來源時間戳。"
    @Published var translationSource = UserDefaults.standard.string(forKey: "translationSource") ?? "en"
    var supportsBackgroundAudio: Bool { (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true }
    var backgroundDescription: String { supportsBackgroundAudio ? "私人安裝版在背景保存錄音並持續即時辨識；切換 App 時 PiP 字幕與即時動態仍持續更新。" : "Playground 版請保持字幕視窗可見；測試背景錄音請使用 IPA。" }
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
    private var captionRevisionCounter = 0
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

    var duration: Double {
        if audioSource == .deviceAudio {
            return max(deviceAudioDuration, session?.lines.last?.end ?? 0)
        }
        return session?.duration ?? 0
    }
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
        if let translated = current.translation(for: line) { return CaptionText.screen(translated.text) }
        if translationDraftKey?.sessionID == current.id && translationDraftKey?.generation == translationGeneration && !translatedDraft.isEmpty {
            return "更新中 · 上次翻譯\n" + CaptionText.screen(translatedDraft)
        }
        return ""
    }
    func setTranslationSource(_ value: String) {
        guard value == "en" || value == "ja", value != translationSource else { return }
        translationSource = value; UserDefaults.standard.set(value, forKey: "translationSource")
        session?.translationSource = value; session?.translations = []
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
        language = value; UserDefaults.standard.set(value, forKey: "recognitionLanguage")
        session?.language = value; loadedModel = nil
        liveDraft = ""; provisional = []
        persist()
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
        recognitionEngine = value; UserDefaults.standard.set(value, forKey: "recognitionEngine")
        session?.recognitionEngine = value; loadedModel = nil
        // Root cause fix: Never restart translation or bump generation on engine switch!
        // Translation session stays alive and receives new text smoothly.
        liveDraft = ""; provisional = []
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
            status = L10n.tr("正在準備語音辨識…", "Preparing speech recognition…")
            resourceState = .preparing(progress: nil)
            progress = nil
            await engine.unload(); await senseVoice.unload()
            if appleSpeech == nil { appleSpeech = AppleSpeechEngine() }
            try await appleSpeech?.prepare(language: session?.language ?? language) { [weak self] value in
                self?.resourceState = .preparing(progress: value)
                self?.progress = value
            }
            loadedModel = "apple"; status = "Apple 即時語音已就緒"; progress = nil
            resourceState = .ready
            return
        }
        await appleSpeech?.cancel(); appleSpeech = nil
        if usesSenseVoice {
            await engine.unload()
            try await senseVoice.load(language: session?.language ?? language) { [weak self] state in
                Task { @MainActor in
                    guard let self, self.isBusy else { return }
                    self.resourceState = state
                    self.status = state.description
                    self.progress = state.progressValue
                }
            }
            loadedModel = "sensevoice"; status = "SenseVoice 已就緒 · 中英混說實驗版"; progress = nil
            resourceState = .ready
            return
        }
        await senseVoice.unload()
        status = "正在載入模型…"
        try await engine.load(name) { [weak self] state in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                self.resourceState = state
                self.status = state.description
                self.progress = state.progressValue
            }
        }
        loadedModel = name; status = "模型已就緒"; progress = nil
        resourceState = .ready
    }

    func start() async {
        guard canStart, let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if audioSource == .microphone {
                let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
                guard granted else {
                    throw LectureError.message(L10n.tr("麥克風未獲授權。請到 iPad 設定允許此 App 使用麥克風，再返回重試。", "Microphone not authorized."))
                }
            } else {
                guard DeviceAudioAvailability.isSupported else {
                    throw LectureError.message(DeviceAudioAvailability.unavailableReason)
                }
            }
            try await loadModel(session?.model ?? model)
            guard UIApplication.shared.applicationState == .active else {
                throw LectureError.message(audioSource == .deviceAudio
                    ? L10n.tr("模型已就緒。請回到 App，再按開始即時字幕。", "Model ready. Return to app to start live captions.")
                    : L10n.tr("模型已就緒。請回到 App，再按開始錄音。", "Model ready. Return to app to start recording."))
            }
            if session == nil {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let eng: TranscriptEngine
                let liveName: String
                if usesAppleSpeech {
                    eng = .apple
                    liveName = "Apple Speech · Live"
                } else if usesSenseVoice {
                    eng = .sensevoice
                    liveName = "SenseVoice · Live"
                } else {
                    eng = .whisper
                    liveName = "Whisper v3 · Live"
                }
                let liveVersion = TranscriptVersion(
                    name: liveName,
                    engine: eng,
                    model: model,
                    language: language,
                    vocabulary: vocabulary.isEmpty ? nil : vocabulary,
                    lines: [],
                    translations: [],
                    translationSource: translationSource,
                    source: .live,
                    isPreferred: true
                )
                let defaultTitle = audioSource == .deviceAudio
                    ? L10n.tr("裝置聲音 \(Date().formatted(date: .abbreviated, time: .shortened))", "Device Audio \(Date().formatted(date: .abbreviated, time: .shortened))")
                    : L10n.tr("課堂 \(Date().formatted(date: .abbreviated, time: .shortened))", "Lecture \(Date().formatted(date: .abbreviated, time: .shortened))")
                session = LectureSession(
                    title: cleanTitle.isEmpty ? defaultTitle : cleanTitle,
                    model: model,
                    language: language,
                    vocabulary: vocabulary,
                    recognitionEngine: recognitionEngine,
                    parts: [],
                    transcriptVersions: [liveVersion],
                    preferredVersionID: liveVersion.id
                )
            } else if session?.transcriptVersions.isEmpty == true {
                let eng: TranscriptEngine = usesAppleSpeech ? .apple : (usesSenseVoice ? .sensevoice : .whisper)
                let liveVersion = TranscriptVersion(
                    name: usesAppleSpeech ? "Apple Speech · Live" : "即時逐字稿",
                    engine: eng,
                    model: session?.model ?? model,
                    language: session?.language ?? language,
                    vocabulary: session?.vocabulary ?? vocabulary,
                    lines: [],
                    translations: [],
                    translationSource: translationSource,
                    source: .live,
                    isPreferred: true
                )
                session?.transcriptVersions = [liveVersion]
                session?.preferredVersionID = liveVersion.id
            }
            session?.translationSource = translationSource
            guard var current = session else { return }

            if audioSource == .microphone {
                let part = AudioPart(fileName: UUID().uuidString + ".pcm16", offset: current.duration,
                    languageChanges: usesAppleSpeech ? [AudioLanguageChange(sample: 0, language: current.language)] : nil,
                    recordingQuality: recordingQuality)
                current.parts.append(part)
                try store.save(current)
                session = current
                if usesAppleSpeech { try await startApple(part, current: current) }
                do {
                    try recorder.start(
                        at: store.audioURL(current, part),
                        allowsPlayback: pipEnabled || PiPPresentationSettings.shared.autoStart
                    )
                }
                catch {
                    // A failed start may still have created a recoverable empty PCM file.
                    session?.parts.removeLast()
                    if let remaining = session { try? store.save(remaining) }
                    throw error
                }
                activePartID = part.id
                draftAudioEnd = part.offset
            } else {
                // Device Audio
                session = current
                deviceAudioDuration = 0
                deviceAudioBufferLock.lock()
                deviceAudioBuffer.removeAll()
                deviceAudioBufferStartOffset = 0
                deviceAudioProcessedSamples = 0
                deviceAudioBufferLock.unlock()
                DeviceAudioCaptureManager.shared.delegate = self
                try await DeviceAudioCaptureManager.shared.start()
                if usesAppleSpeech {
                    try await startAppleDeviceAudio(current: current)
                }
                DeviceAudioCaptureManager.shared.recordAudioSessionEvent("ASR start")
                draftAudioEnd = 0
            }

            lastPreviewSample = 0
            previousHypothesis = []; liveDraft = ""
            isRecording = true
            status = audioSource == .deviceAudio
                ? L10n.tr("正在擷取裝置聲音 · 無錄音檔", "Capturing Device Audio · No audio saved")
                : L10n.tr("正在錄音 · 聲音只保存在本機", "Recording · Audio saved on device")
            CaptionFeed.shared.update(
                original: caption,
                translation: validTranslatedDraft,
                isRecording: true,
                isPaused: false
            )
            LiveActivityCoordinator.shared.start(
                lectureID: current.id,
                title: current.title,
                engineName: usesAppleSpeech ? "Apple Live" : (usesSenseVoice ? "SenseVoice" : "Whisper")
            )
            UIApplication.shared.isIdleTimerDisabled = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            worker = Task { [weak self] in await self?.streamLoop() }
        } catch {
            await appleSpeech?.cancel()
            if audioSource == .deviceAudio {
                await DeviceAudioCaptureManager.shared.stop()
            }
            fail(audioSource == .deviceAudio
                ? L10n.tr("無法開始裝置聲音擷取。", "Unable to start Device Audio.")
                : L10n.tr("無法開始錄音。", "Unable to start recording."), error)
        }
    }

    private func tick() {
        guard isRecording else { return }
        if audioSource == .microphone {
            updateAudioCount()
            saveCounter += 1
            if saveCounter >= 20 { saveCounter = 0; persist() }
            if let problem = recorder.snapshot().error { interrupt(problem) }
        } else {
            saveCounter += 1
            if saveCounter >= 20 {
                saveCounter = 0
                if sessionStorageMode == .saveTranscript { persist() }
            }
        }
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
            if audioSource == .deviceAudio {
                if usesAppleSpeech {
                    while isRecording {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                } else if usesSenseVoice {
                    while isRecording {
                        if !canProcessLiveAudio { try await Task.sleep(nanoseconds: 300_000_000); continue }
                        try await decodeDeviceAudioSenseVoice()
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                } else if usesWhisper {
                    while isRecording {
                        if !canProcessLiveAudio { try await Task.sleep(nanoseconds: 300_000_000); continue }
                        try await decodeDeviceAudioWhisper()
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            } else {
                if usesAppleSpeech {
                    try await streamApple()
                } else {
                    while isRecording {
                        if !canProcessLiveAudio { try await Task.sleep(nanoseconds: 300_000_000); continue }
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
            }
        } catch is CancellationError {
            // Cancellation never marks unfinished audio as confirmed.
        } catch {
            await appleSpeech?.cancel()
            if isRecording && !isInForeground && supportsBackgroundAudio {
                status = "背景辨識已暫停，錄音仍持續保存；回到畫面後繼續"
            } else {
                stopCapture()
                fail("辨識暫停，已錄聲音保留在本機，可按「補辨識」。", error)
            }
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
        let reviewing = current.transcriptionPass == "context30"
        let left = min(reviewing ? ReviewWindow.context : SenseVoiceContext.overlap, part.processedSamples)
        let readStart = part.processedSamples - left
        let count = min(reviewing ? ReviewWindow.maximumSamples : SenseVoiceWindow.maximumSamples, part.sampleCount - readStart)
        guard count > left else { return }
        isDecoding = true
        defer { isDecoding = false }
        let file = store.audioURL(current, part)
        let samples = try await Task.detached(priority: .userInitiated) {
            try PCMRecorder.read(file, from: readStart, count: count)
        }.value
        guard samples.count == count else { throw LectureError.message("SenseVoice 音訊讀取不完整，保留進度供重試。") }
        let atEnd = final && readStart + count == part.sampleCount
        let window = reviewing ? ReviewWindow.choose(samples, left: left, atEnd: atEnd)
            : SenseVoiceContext.choose(samples, left: left, atEnd: atEnd)
        guard !window.owned.isEmpty else { return }
        let started = Date()
        // Low-volume speech must reach the model too; VAD only chooses boundaries.
        let decoded = try await senseVoice.transcribeDetailed(Array(samples.prefix(window.inputCount)), owned: window.owned)
        let text = decoded.text
        try Task.checkCancellation()
        guard session?.id == current.id, let index = session?.parts.firstIndex(where: { $0.id == id }) else { return }
        lastDecodeSeconds = Date().timeIntervalSince(started)
        let start = part.offset + Double(part.processedSamples) / 16000
        let end = start + Double(window.owned.count) / 16000
        draftAudioEnd = end; liveDraft = ""
        senseVoiceInputStatus = "模型輸入 \(window.inputCount) 個樣本；本段 \(window.owned.count)，前文 \(left)，後文 \(window.inputCount - window.owned.upperBound)（16 kHz）"
        var lines = text.isEmpty ? [] : [TranscriptLine(start: start, end: end, text: text)]
        if reviewing, !decoded.words.isEmpty {
            let offset = part.offset + Double(readStart) / 16000
            lines = CaptionText.lines(decoded.words.map { .init(text: $0.text, start: offset + $0.start, end: offset + $0.end) })
            for index in lines.indices { lines[index].approximateTiming = true }
        }
        if window.commit {
            guard var updated = session else { return }
            let corrected = lines.map { TranscriptLine(start: $0.start, end: $0.end, text: CourseVocabulary.shared.correctFinalText($0.text)) }
            updated.appendConfirmed(corrected)
            updated.parts[index].processedSamples += window.owned.count
            try store.save(updated)
            session = updated; lastSaved = Date()
            provisional = []; previousHypothesis = []
        } else { provisional = lines }
    }

    private func stopCapture(endLiveActivity: Bool = true) {
        guard isRecording else { return }
        if audioSource == .deviceAudio {
            Task { @MainActor in
                await DeviceAudioCaptureManager.shared.stop()
            }
        } else {
            recorder.stop()
            updateAudioCount()
        }
        isRecording = false; level = 0
        meter?.invalidate(); meter = nil
        UIApplication.shared.isIdleTimerDisabled = false

        if audioSource != .deviceAudio {
            persist()
        }

        CaptionFeed.shared.update(isRecording: false, isPaused: !endLiveActivity)
        if endLiveActivity { LiveActivityCoordinator.shared.stop() }
    }

    func pause() async {
        guard isRecording, !isBusy else { return }
        if audioSource == .deviceAudio {
            await endLecture()
            return
        }
        isBusy = true
        LiveActivityCoordinator.shared.updatePause(isPaused: true, elapsed: duration)
        stopCapture(endLiveActivity: false)
        status = L10n.tr("正在補完最後一段…", "Finishing pending audio…")
        await worker?.value
        worker = nil
        do {
            try await finishPending()
            await archiveCompletedAudio()
            status = L10n.tr("已暫停並儲存，可繼續同一堂課", "Paused and saved; can resume this lecture")
        } catch { fail(L10n.tr("最後一段尚未完成；音訊已保留，請按「補辨識」。", "Last segment pending; audio saved, tap Catch Up."), error) }
        isBusy = false
        reloadHistory()
    }

    func endLecture() async {
        if isRecording {
            if audioSource == .deviceAudio {
                isBusy = true
                stopCapture(endLiveActivity: true)
                await worker?.value
                worker = nil
                isBusy = false
                switch deviceAudioSavePreference {
                case .alwaysSave: resolveDeviceAudioSave(save: true)
                case .alwaysDiscard: resolveDeviceAudioSave(save: false)
                case .askEveryTime:
                    deviceAudioAwaitingSaveDecision = true
                    status = L10n.tr("即時字幕已結束，請選擇儲存或捨棄逐字稿", "Live Captions ended. Save or discard the transcript.")
                }
                return
            } else {
                await pause()
            }
        }
        LiveActivityCoordinator.shared.stop()
        CaptionFeed.shared.update(isRecording: false, isPaused: false)
        status = L10n.tr("課堂已結束並儲存", "Lecture ended and saved")
    }

    func switchRecognitionEngine(to value: String) async {
        guard ["apple", "sensevoice", "whisper"].contains(value), value != recognitionEngine else { return }
        guard isRecording else { setRecognitionEngine(value); return }
        guard !isBusy, let current = session else { return }
        isBusy = true
        let oldEngine = recognitionEngine
        status = L10n.tr("正在準備新辨識引擎；目前引擎繼續運作…", "Preparing the new recognizer while the current engine continues…")
        do {
            var preparedApple: (any LiveSpeechEngine)?
            if value == "apple" {
                guard #available(iOS 26.0, *) else { throw LectureError.message("Apple Speech requires iOS 26+") }
                let candidate = AppleSpeechEngine()
                try await candidate.prepare(language: RecognitionLanguage.primary(language) ?? "zh") { _ in }
                preparedApple = candidate
            } else if value == "sensevoice" {
                try await senseVoice.load(language: language, progressState: { _ in })
            } else {
                try await engine.load(model, progressState: { _ in })
            }

            let boundarySamples: Int
            let boundaryTime: TimeInterval
            if audioSource == .deviceAudio {
                boundarySamples = Int(deviceAudioDuration * 16_000)
                boundaryTime = deviceAudioDuration
            } else if let part = current.parts.last {
                updateAudioCount()
                boundarySamples = session?.parts.last?.sampleCount ?? part.sampleCount
                boundaryTime = part.offset + Double(boundarySamples) / 16_000
            } else { boundarySamples = 0; boundaryTime = duration }
            let buffers = DeviceAudioCaptureManager.shared.diagnostics.totalBuffersReceived
            lastASRSwitchBoundary = ASRSwitchBoundary(engine: oldEngine, sampleIndex: boundarySamples,
                                                      timestamp: boundaryTime, totalBuffers: buffers)
                .switching(to: value, atSample: boundarySamples, timestamp: boundaryTime)

            worker?.cancel(); await worker?.value; worker = nil
            if oldEngine == "apple" { await appleSpeech?.cancel() }
            recognitionEngine = value
            UserDefaults.standard.set(value, forKey: "recognitionEngine")
            session?.recognitionEngine = value
            liveDraft = ""; provisional = []; previousHypothesis = []
            if audioSource == .deviceAudio {
                deviceAudioProcessedSamples = boundarySamples
                if value == "apple", let preparedApple {
                    appleSpeech = preparedApple
                    try await startAppleDeviceAudio(current: session ?? current)
                }
            } else if let index = session?.parts.indices.last {
                session?.parts[index].processedSamples = boundarySamples
                if value == "apple", let preparedApple, let part = session?.parts[index] {
                    appleSpeech = preparedApple
                    try await startApple(part, current: session ?? current)
                }
            }
            loadedModel = value == "whisper" ? model : value
            worker = Task { [weak self] in await self?.streamLoop() }
            status = L10n.tr("辨識引擎已切換，擷取與翻譯持續", "Recognizer switched; capture and translation continue")
        } catch {
            recognitionEngine = oldEngine
            status = L10n.tr("新引擎尚未就緒，目前辨識繼續運作", "New model not ready; current recognizer continues")
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func resolveDeviceAudioSave(save: Bool) {
        guard audioSource == .deviceAudio else { return }
        deviceAudioAwaitingSaveDecision = false
        if save {
            guard let session, let store else { return }
            do {
                try store.save(session)
                lastSaved = Date()
                reloadHistory()
                status = L10n.tr("已儲存逐字稿與翻譯（無裝置音訊檔）", "Transcript and translations saved (no Device Audio file).")
            } catch { fail(L10n.tr("無法儲存逐字稿。", "Unable to save transcript."), error) }
        } else {
            session = nil; liveDraft = ""; provisional = []; translatedDraft = ""
            translationDraftSource = ""; translationDraftKey = nil
            reloadHistory()
            status = L10n.tr("已捨棄本次裝置聲音逐字稿", "Device Audio transcript discarded.")
        }
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

    func retranscribe(
        session targetSession: LectureSession,
        engine transcriptEngine: TranscriptEngine = .whisper,
        model modelName: String = SpeechModel.turbo.rawValue,
        language lang: String = "zh",
        vocabulary vocab: String = "",
        autoTranslate: Bool = false
    ) async throws -> TranscriptVersion {
        guard let store else { throw LectureError.message("儲存空間未就緒。") }
        guard !targetSession.parts.isEmpty, targetSession.parts.contains(where: { $0.sampleCount > 0 }) else {
            throw LectureError.message("這堂課沒有可重新轉錄的音訊。")
        }
        isBusy = true
        status = "正在載入辨識模型…"
        defer {
            isBusy = false
            progress = nil
        }

        var decodedLines: [TranscriptLine] = []
        let totalSamples = targetSession.parts.reduce(0) { $0 + $1.sampleCount }
        var processedOverallSamples = 0

        if transcriptEngine == .whisper {
            await senseVoice.unload()
            await appleSpeech?.cancel()
            status = "正在載入 Whisper 模型…"
            try await engine.load(modelName) { [weak self] msg, frac in
                Task { @MainActor in
                    self?.status = msg
                    self?.progress = frac
                }
            }
            loadedModel = modelName

            for part in targetSession.parts {
                guard part.sampleCount > 0 else { continue }
                let file = store.audioURL(targetSession, part)
                var partCursor = 0
                var previousHypothesis: [TranscriptLine] = []
                let hasWordTiming = await engine.supportsWordTiming()

                while partCursor < part.sampleCount {
                    try Task.checkCancellation()
                    let overlap = hasWordTiming ? min(4000, partCursor) : 0
                    let available = part.sampleCount - partCursor
                    let count = min(26 * 16000, available + overlap)
                    let offset = part.offset + Double(partCursor - overlap) / 16000.0
                    let cursorTime = part.offset + Double(partCursor) / 16000.0
                    let isFinalChunk = (partCursor + count - overlap >= part.sampleCount)

                    status = "正在以 Whisper v3 重新轉錄（\(Int(Double(processedOverallSamples) / Double(max(1, totalSamples)) * 100))%）…"
                    progress = Double(processedOverallSamples) / Double(max(1, totalSamples))

                    let decoded = try await engine.transcribe(
                        file: file,
                        start: partCursor - overlap,
                        count: count,
                        offset: offset,
                        language: lang,
                        vocabulary: vocab,
                        final: isFinalChunk
                    ) { _, _ in }

                    let lines = overlap > 0 ? CaptionText.after(decoded.lines, time: cursorTime) : decoded.lines
                    let decision = WindowDecision.make(
                        lines: lines,
                        samples: count,
                        offset: offset,
                        final: isFinalChunk,
                        previous: previousHypothesis,
                        utteranceEnded: decoded.endsWithPause
                    )

                    for confirmed in decision.confirmed {
                        decodedLines.append(confirmed)
                    }
                    previousHypothesis = decision.provisional

                    let advanced = max(16000, decision.consumed > overlap ? (decision.consumed - overlap) : (count - overlap))
                    partCursor += min(advanced, available)
                    processedOverallSamples += min(advanced, available)
                }
                if !previousHypothesis.isEmpty {
                    decodedLines.append(contentsOf: previousHypothesis)
                }
            }
        } else if transcriptEngine == .sensevoice {
            await engine.unload()
            await appleSpeech?.cancel()
            status = "正在載入 SenseVoice 模型…"
            try await senseVoice.load(language: lang) { [weak self] msg, frac in
                Task { @MainActor in
                    self?.status = msg
                    self?.progress = frac
                }
            }
            loadedModel = "sensevoice"

            for part in targetSession.parts {
                guard part.sampleCount > 0 else { continue }
                let file = store.audioURL(targetSession, part)
                var partCursor = 0

                while partCursor < part.sampleCount {
                    try Task.checkCancellation()
                    let left = min(ReviewWindow.context, partCursor)
                    let readStart = partCursor - left
                    let count = min(ReviewWindow.maximumSamples, part.sampleCount - readStart)
                    guard count > left else { break }

                    status = "正在以 SenseVoice 重新轉錄（\(Int(Double(processedOverallSamples) / Double(max(1, totalSamples)) * 100))%）…"
                    progress = Double(processedOverallSamples) / Double(max(1, totalSamples))

                    let samples = try await Task.detached(priority: .userInitiated) {
                        try PCMRecorder.read(file, from: readStart, count: count)
                    }.value
                    let atEnd = (readStart + count >= part.sampleCount)
                    let window = ReviewWindow.choose(samples, left: left, atEnd: atEnd)
                    guard !window.owned.isEmpty else { break }

                    let decoded = try await senseVoice.transcribeDetailed(Array(samples.prefix(window.inputCount)), owned: window.owned)
                    if !decoded.words.isEmpty {
                        let offset = part.offset + Double(readStart) / 16000.0
                        let lines = CaptionText.lines(decoded.words.map { .init(text: $0.text, start: offset + $0.start, end: offset + $0.end) })
                        decodedLines.append(contentsOf: lines)
                    } else if !decoded.text.isEmpty {
                        let start = part.offset + Double(partCursor) / 16000.0
                        let end = start + Double(window.owned.count) / 16000.0
                        decodedLines.append(TranscriptLine(start: start, end: end, text: decoded.text))
                    }
                    partCursor += window.owned.count
                    processedOverallSamples += window.owned.count
                }
            }
        }

        decodedLines.sort { $0.start < $1.start }

        let modelLabel: String
        if modelName == SpeechModel.turbo.rawValue { modelLabel = "Turbo" }
        else if modelName == SpeechModel.base.rawValue { modelLabel = "Base" }
        else if modelName == SpeechModel.small.rawValue { modelLabel = "Small" }
        else { modelLabel = modelName }

        let terms = vocab.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).filter { !$0.isEmpty }
        let vocabSummary = terms.isEmpty ? "" : " · \(terms.count) 專有詞"
        let versionName: String
        if transcriptEngine == .whisper {
            versionName = "Whisper v3 · \(modelLabel)\(vocabSummary)"
        } else if transcriptEngine == .sensevoice {
            versionName = "SenseVoice · 課後轉錄"
        } else {
            versionName = "課後重新轉錄"
        }

        let newVersion = TranscriptVersion(
            id: UUID(),
            createdAt: Date(),
            name: versionName,
            engine: transcriptEngine,
            model: modelName,
            language: lang,
            vocabulary: vocab.isEmpty ? nil : vocab,
            lines: decodedLines,
            translations: nil,
            translationSource: targetSession.translationSource,
            source: .retranscription,
            isPreferred: true
        )

        var updatedSession = targetSession
        for i in updatedSession.transcriptVersions.indices {
            updatedSession.transcriptVersions[i].isPreferred = false
        }
        updatedSession.transcriptVersions.append(newVersion)
        updatedSession.preferredVersionID = newVersion.id
        try store.save(updatedSession)

        if session?.id == updatedSession.id {
            session = updatedSession
            if autoTranslate {
                translationEnabled = true
                restartTranslation()
            }
        }
        reloadHistory()
        status = "重新轉錄完成 · 已新增版本「\(versionName)」"
        return newVersion
    }

    func retranscribeRecording() async {
        guard canManageSessions, let source = session else { return }
        persist()
        do {
            _ = try await retranscribe(
                session: source,
                engine: recognitionEngine == "sensevoice" ? .sensevoice : .whisper,
                model: model,
                language: language,
                vocabulary: vocabulary,
                autoTranslate: translationEnabled
            )
        } catch {
            fail("重新轉錄未完成；原始錄音保留。", error)
        }
    }

    func selectTranscriptVersion(sessionID: UUID, versionID: UUID) {
        guard var current = (session?.id == sessionID ? session : history.first(where: { $0.id == sessionID })) else { return }
        guard current.transcriptVersions.contains(where: { $0.id == versionID }) else { return }
        current.preferredVersionID = versionID
        do {
            try store?.save(current)
            if session?.id == sessionID { session = current }
            reloadHistory()
        } catch {
            fail("切換逐字稿版本失敗。", error)
        }
    }

    func setPreferredVersion(sessionID: UUID, versionID: UUID) {
        guard var current = (session?.id == sessionID ? session : history.first(where: { $0.id == sessionID })) else { return }
        var versions = current.transcriptVersions
        for i in versions.indices {
            versions[i].isPreferred = (versions[i].id == versionID)
        }
        current.transcriptVersions = versions
        current.preferredVersionID = versionID
        do {
            try store?.save(current)
            if session?.id == sessionID { session = current }
            reloadHistory()
            status = "已設定預設逐字稿版本"
        } catch {
            fail("更新預設版本失敗。", error)
        }
    }

    func setPreferredTranslationVersion(sessionID: UUID, versionID: UUID, translationVersionID: UUID) {
        guard var current = (session?.id == sessionID ? session : history.first(where: { $0.id == sessionID })) else { return }
        guard let idx = current.transcriptVersions.firstIndex(where: { $0.id == versionID }) else { return }
        current.transcriptVersions[idx].preferredTranslationVersionID = translationVersionID
        if var tvs = current.transcriptVersions[idx].translationVersions, !tvs.isEmpty {
            for i in 0..<tvs.count {
                tvs[i].isPreferred = (tvs[i].id == translationVersionID)
            }
            current.transcriptVersions[idx].translationVersions = tvs
        }
        do {
            try store?.save(current)
            if session?.id == sessionID { session = current }
            reloadHistory()
        } catch {
            fail("無法切換翻譯版本", error)
        }
    }

    func deleteTranscriptVersion(sessionID: UUID, versionID: UUID) {
        guard canManageSessions, var current = (session?.id == sessionID ? session : history.first(where: { $0.id == sessionID })) else { return }
        guard current.transcriptVersions.count > 1 else {
            fail("無法刪除唯一的逐字稿版本。", LectureError.message("每堂課至少保留一個版本。如需清除整堂課，請刪除整堂課。"))
            return
        }
        current.transcriptVersions.removeAll { $0.id == versionID }
        if current.preferredVersionID == versionID {
            current.preferredVersionID = current.transcriptVersions.first(where: { $0.isPreferred })?.id ?? current.transcriptVersions.first?.id
        }
        do {
            try store?.save(current)
            if session?.id == sessionID { session = current }
            reloadHistory()
            status = "已刪除逐字稿版本（錄音已保留）"
        } catch {
            fail("刪除版本失敗。", error)
        }
    }

    func prepareClip(start: Double, end: Double) async -> URL? {
        guard canManageSessions, let source = session, let store else { return nil }
        isBusy = true; defer { isBusy = false }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try StoredAudio.clip(source, store: store, start: start, end: end)
            }.value
        } catch { fail("無法準備核對片段。", error); return nil }
    }

    func reviewRange(start: Double, end: Double) async -> [TranscriptLine]? {
        guard canManageSessions, let source = session, let store else { return nil }
        isBusy = true; defer { isBusy = false; progress = nil }
        do {
            _ = try AudioTimeline.slices(source, start: start, end: end)
            await engine.unload(); await appleSpeech?.cancel(); loadedModel = nil
            try await senseVoice.load(language: source.language) { [weak self] message, _ in
                Task { @MainActor in self?.status = message }
            }
            var cursor = start; var words: [TranscriptWord] = []
            while cursor < end {
                try Task.checkCancellation()
                let stop = min(end, cursor + 24)
                let from = max(0, cursor - 3), through = min(source.duration, stop + 3)
                let slices = try AudioTimeline.slices(source, start: from, end: through)
                let samples = try await Task.detached(priority: .userInitiated) {
                    var buffer: [Float] = []
                    for slice in slices { buffer += try StoredAudio.read(store.audioURL(source, slice.part), from: slice.start, count: slice.count) }
                    return buffer
                }.value
                let first = Int((cursor * 16000).rounded()) - Int((from * 16000).rounded())
                let last = Int((stop * 16000).rounded()) - Int((from * 16000).rounded())
                let decoded = try await senseVoice.transcribeDetailed(samples, owned: first..<last)
                words += decoded.words.map { .init(text: $0.text, start: from + $0.start, end: from + $0.end) }
                cursor = stop
            }
            var lines = CaptionText.lines(words)
            for i in lines.indices { lines[i].approximateTiming = true }
            status = "選段重辨識完成；請比較原文後決定是否採用"
            return lines
        } catch { fail("選段重辨識失敗，原文保留。", error); return nil }
    }

    func applyReview(_ original: TranscriptLine, replacements: [TranscriptLine], sessionID: UUID) {
        guard canManageSessions, var current = session, current.id == sessionID,
              let index = current.lines.firstIndex(where: { $0.id == original.id }),
              current.lines[index] == original, original.userEdited != true, !replacements.isEmpty else { return }
        current.previousLines = current.lines
        current.lines.replaceSubrange(index...index, with: replacements)
        current.translations?.removeAll { $0.id == original.id }
        saveRevision(current)
    }

    func unlockLine(_ id: UUID) {
        guard canManageSessions, var current = session, let index = current.lines.firstIndex(where: { $0.id == id }) else { return }
        current.lines[index].userEdited = false; saveRevision(current)
    }

    func undoReview() {
        guard canManageSessions, var current = session, let previous = current.previousLines else { return }
        current.lines = previous; current.previousLines = nil
        current.translations = nil; saveRevision(current)
    }

    func analyzeSpeakers() async {
        guard canManageSessions, let source = session, let store, source.speakerTurns == nil else { return }
        isBusy = true; defer { isBusy = false; progress = nil }
        do {
            await engine.unload(); await senseVoice.unload(); await appleSpeech?.cancel(); loadedModel = nil
            let files = source.parts.map { store.audioURL(source, $0) }
            let result = try await SpeakerAnalysis().analyze(source, files: files) { [weak self] message in
                Task { @MainActor in self?.status = message }
            }
            guard var current = session, current.id == source.id else { return }
            current.speakerTurns = result.turns; current.speakerNames = result.names
            current.previousLines = current.lines
            // Split only machine text with acoustic anchors. User edits stay intact.
            current.lines = current.lines.flatMap { line -> [TranscriptLine] in
                guard line.userEdited != true, let words = line.words, !words.isEmpty else { return [line] }
                var output: [TranscriptLine] = []; var group: [TranscriptWord] = []; var groupID: String?
                func flush() {
                    guard !group.isEmpty else { return }
                    var rows = CaptionText.lines(group)
                    for i in rows.indices { rows[i].speakerID = groupID; rows[i].approximateTiming = line.approximateTiming }
                    output += rows; group = []
                }
                for word in words {
                    let ids = Set(result.turns.filter { $0.start <= word.start && $0.end > word.start }.map(\.speakerID))
                    let id = ids.count == 1 ? ids.first : nil
                    if !group.isEmpty && id != groupID { flush() }
                    groupID = id; group.append(word)
                }
                flush(); return output
            }
            let retained = Set(current.lines.map(\.id)); current.translations?.removeAll { !retained.contains($0.id) }
            try store.save(current); session = current; reloadHistory()
            status = "講者分析完成（beta）；可改名、合併及修正段落講者"
        } catch { fail("講者分析未完成，原錄音與文字保留。", error) }
    }

    func renameSpeaker(_ id: String, name: String) {
        guard canManageSessions, var current = session else { return }
        let text = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !text.isEmpty else { return }
        current.speakerNames?[id] = text; saveRevision(current)
    }

    func assignSpeaker(_ lineID: UUID, speaker: String?) {
        guard canManageSessions, var current = session, let index = current.lines.firstIndex(where: { $0.id == lineID }) else { return }
        current.lines[index].speakerID = speaker; current.previousLines = nil; saveRevision(current)
    }

    func mergeSpeaker(_ from: String, into to: String) {
        guard canManageSessions, var current = session, from != to, current.speakerNames?[to] != nil else { return }
        for i in current.lines.indices where current.lines[i].speakerID == from { current.lines[i].speakerID = to }
        for i in current.speakerTurns?.indices ?? 0..<0 {
            if current.speakerTurns?[i].speakerID == from { current.speakerTurns?[i].speakerID = to }
        }
        current.speakerNames?.removeValue(forKey: from); current.previousLines = nil; saveRevision(current)
    }

    private func saveRevision(_ current: LectureSession) {
        do { try store?.save(current); session = current; lastSaved = Date(); reloadHistory() }
        catch { fail("無法保存修改。", error) }
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
        isInForeground = false
        if supportsBackgroundAudio && isRecording {
            updateAudioCount(); persist()
            status = "背景錄音與即時字幕運作中"
        } else if !isRecording {
            // App backgrounded while not recording
        } else {
            interrupt("App 已進入背景，錄音已暫停")
        }
    }
    func foregrounded() {
        isInForeground = true
        if isRecording && worker == nil {
            worker = Task { [weak self] in
                guard let self else { return }
                do {
                    try await loadModel(session?.model ?? model)
                    if usesAppleSpeech, let current = session, let part = current.parts.last { try await startApple(part, current: current) }
                    await streamLoop()
                } catch { stopCapture(); worker = nil; fail("恢復辨識失敗，聲音已保存。", error) }
            }
        }
    }
    func bookmark(_ note: String) {
        guard session != nil else { return }
        updateAudioCount()
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        session?.bookmarks.append(Bookmark(seconds: duration, note: value.isEmpty ? "重點" : value))
        persist()
    }
    func updateLine(_ id: UUID, text: String) {
        guard canManageSessions else { return }
        guard let index = session?.lines.firstIndex(where: { $0.id == id }) else { return }
        session?.lines[index].text = text
        session?.lines[index].words = nil
        session?.lines[index].userEdited = true
        session?.previousLines = nil
        session?.translations?.removeAll { $0.id == id }
        persist()
    }
    func updateTiming(_ id: UUID, start: Double, end: Double) -> Bool {
        guard canManageSessions, var current = session, let index = current.lines.firstIndex(where: { $0.id == id }) else { return false }
        do { _ = try AudioTimeline.slices(current, start: start, end: end) }
        catch { errorMessage = error.localizedDescription; return false }
        current.lines[index].start = start; current.lines[index].end = end
        current.lines[index].words = nil; current.lines[index].approximateTiming = false
        current.previousLines = nil; saveRevision(current); return session?.lines[index].start == start
    }
    func rename(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session?.title = text; title = text; persist()
    }
    func renameLecture(_ id: UUID, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if session?.id == id {
            rename(value)
        } else if let store = try? SessionStore(), var s = store.load(id) {
            s.title = value
            try? store.save(s)
            reloadHistory()
        }
    }
    func updateVersionLine(sessionID: UUID, versionID: UUID, lineID: UUID, text: String) {
        guard canManageSessions else { return }
        if session?.id == sessionID {
            if let vIdx = session?.transcriptVersions.firstIndex(where: { $0.id == versionID }),
               let lIdx = session?.transcriptVersions[vIdx].lines.firstIndex(where: { $0.id == lineID }) {
                session?.transcriptVersions[vIdx].lines[lIdx].text = text
                session?.transcriptVersions[vIdx].lines[lIdx].words = nil
                session?.transcriptVersions[vIdx].lines[lIdx].userEdited = true
                session?.transcriptVersions[vIdx].translations?.removeAll { $0.id == lineID }
                persist()
            }
        } else if let store = try? SessionStore(), var s = store.load(sessionID) {
            if let vIdx = s.transcriptVersions.firstIndex(where: { $0.id == versionID }),
               let lIdx = s.transcriptVersions[vIdx].lines.firstIndex(where: { $0.id == lineID }) {
                s.transcriptVersions[vIdx].lines[lIdx].text = text
                s.transcriptVersions[vIdx].lines[lIdx].words = nil
                s.transcriptVersions[vIdx].lines[lIdx].userEdited = true
                s.transcriptVersions[vIdx].translations?.removeAll { $0.id == lineID }
                try? store.save(s)
                reloadHistory()
            }
        }
    }
    func bookmark(sessionID: UUID, note: String, at seconds: Double) {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = Bookmark(seconds: max(0, seconds), note: value.isEmpty ? "重點" : value)
        if session?.id == sessionID {
            session?.bookmarks.append(b)
            persist()
        } else if let store = try? SessionStore(), var s = store.load(sessionID) {
            s.bookmarks.append(b)
            try? store.save(s)
            reloadHistory()
        }
    }
    func newLecture() {
        guard canManageSessions else { return }
        senseVoiceInputStatus = ""
        persist(); reloadHistory()
        session = nil; title = ""; provisional = []; search = ""
        restartTranslation()
        translatedDraft = ""; summaryStatus = ""
        liveDraft = ""; previousHypothesis = []; lastDecodeSeconds = nil; draftAudioEnd = 0; lastSaved = nil
        status = "準備新的一堂課"
    }
    func open(_ saved: LectureSession) {
        guard canManageSessions else { return }
        senseVoiceInputStatus = ""
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
        imported.translationSource = translationSource
        imported.transcriptionPass = "context30"
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
    func export(_ format: TranscriptFormat, version: TranscriptVersion? = nil) -> URL? {
        guard let session, let store else { return nil }
        do { return try store.export(session, version: version, format: format) }
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
        if audioSource == .deviceAudio {
            return
        }
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
                    self.session?.previousLines = nil
                    let corrected = CourseVocabulary.shared.correctFinalText(confirmed.text)
                    let newLine = TranscriptLine(start: offset + confirmed.start, end: offset + confirmed.end, text: corrected)
                    self.session?.lines.append(newLine)
                    print("CaptionLatency final_transcript=\(Date().timeIntervalSince1970)")
                    LiveActivityCoordinator.shared.updateTranscript(original: corrected, translation: self.validTranslatedDraft)
                    CaptionFeed.shared.update(original: self.caption, translation: self.validTranslatedDraft)
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
            if isRecording && !canProcessLiveAudio { try await Task.sleep(nanoseconds: 300_000_000); continue }
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
    func saveTranslation(sessionID: UUID, line: TranscriptLine, text: String, versionID: UUID? = nil) {
        guard session?.id == sessionID else { return }
        let targetID = versionID ?? session?.preferredVersionID
        let idx = (targetID != nil ? session?.transcriptVersions.firstIndex(where: { $0.id == targetID }) : nil) ?? session?.preferredVersionIndex ?? -1
        guard idx >= 0, let currentVersions = session?.transcriptVersions, idx < currentVersions.count else {
            var values = session?.translations ?? []
            values.removeAll { $0.id == line.id }
            values.append(TranslatedLine(id: line.id, source: line.text, text: text))
            session?.translations = values
            persist()
            return
        }
        var values = session?.transcriptVersions[idx].translations ?? []
        values.removeAll { $0.id == line.id }
        values.append(TranslatedLine(id: line.id, source: line.text, text: text))
        session?.transcriptVersions[idx].translations = values
        if let tvID = session?.transcriptVersions[idx].preferredTranslationVersionID,
           let tvIndex = session?.transcriptVersions[idx].translationVersions?.firstIndex(where: { $0.id == tvID }) {
            session?.transcriptVersions[idx].translationVersions?[tvIndex].provider = translationProvider
            session?.transcriptVersions[idx].translationVersions?[tvIndex].sourceLocale = translationSource
            session?.transcriptVersions[idx].translationVersions?[tvIndex].targetLocale = translationTarget
            session?.transcriptVersions[idx].translationVersions?[tvIndex].strategy = translationStrategy.rawValue
            session?.transcriptVersions[idx].translationVersions?[tvIndex].recognitionEngine = recognitionEngine
            session?.transcriptVersions[idx].translationVersions?[tvIndex].recognitionLanguage = language
        }
        persist()
        print("CaptionLatency translation_update=\(Date().timeIntervalSince1970)")
        LiveActivityCoordinator.shared.updateTranscript(original: line.text, translation: text)
        CaptionFeed.shared.update(original: caption, translation: text)
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
    private func startAppleDeviceAudio(current: LectureSession) async throws {
        guard let appleSpeech else { throw LectureError.message(L10n.tr("請先載入 Apple 語音模型。", "Please load Apple speech model first.")) }
        let generation = UUID(); activeDecodeID = generation
        appleCaptions = AppleCaptionState()
        liveDraft = ""; provisional = []; restartTranslation()
        let selectedLanguage = current.language
        let offset = duration
        try await appleSpeech.start(language: selectedLanguage) { [weak self] result in
            guard let self, self.activeDecodeID == generation, self.session?.id == current.id,
                  result.start.isFinite, result.end.isFinite else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.draftAudioEnd = max(self.draftAudioEnd, offset + result.end)
            let line = TranscriptLine(start: result.start, end: result.end, text: text)
            let confirmed = self.appleCaptions.receive(line, final: result.isFinal)
            if result.isFinal {
                if let confirmed {
                    self.session?.previousLines = nil
                    let corrected = CourseVocabulary.shared.correctFinalText(confirmed.text)
                    let newLine = TranscriptLine(start: offset + confirmed.start, end: offset + confirmed.end, text: corrected)
                    self.session?.lines.append(newLine)
                    print("CaptionLatency final_transcript=\(Date().timeIntervalSince1970)")
                    LiveActivityCoordinator.shared.updateTranscript(original: corrected, translation: self.validTranslatedDraft)
                    CaptionFeed.shared.update(original: self.caption, translation: self.validTranslatedDraft)
                }
                if self.sessionStorageMode == .saveTranscript {
                    self.persist()
                }
            }
            self.liveDraftStart = offset + (self.appleCaptions.draft?.start ?? result.end)
            self.liveDraft = self.appleCaptions.draft?.text ?? ""
            self.provisional = []
        }
        language = selectedLanguage
    }

    private func decodeDeviceAudioSenseVoice() async throws {
        deviceAudioBufferLock.lock()
        let currentSamples = deviceAudioBuffer
        let startSampleIndex = deviceAudioBufferStartOffset
        deviceAudioBufferLock.unlock()

        let available = (startSampleIndex + currentSamples.count) - deviceAudioProcessedSamples
        guard available >= 32000 else { return }

        let localReadStart = max(0, deviceAudioProcessedSamples - startSampleIndex)
        let localSamples = Array(currentSamples.suffix(from: localReadStart))
        let left = min(16000, localReadStart)

        let window = SenseVoiceContext.choose(localSamples, left: left, atEnd: false)
        guard !window.owned.isEmpty else { return }

        let started = Date()
        let decoded = try await senseVoice.transcribeDetailed(Array(localSamples.prefix(window.inputCount)), owned: window.owned)
        let text = decoded.text
        try Task.checkCancellation()
        guard isRecording, let _ = session else { return }
        lastDecodeSeconds = Date().timeIntervalSince(started)

        let start = Double(deviceAudioProcessedSamples) / 16000
        let end = start + Double(window.owned.count) / 16000
        draftAudioEnd = end; liveDraft = ""
        senseVoiceInputStatus = L10n.tr("裝置聲音輸入 \(window.inputCount) 個樣本；本段 \(window.owned.count)（16 kHz）", "Device audio input \(window.inputCount) samples; segment \(window.owned.count) (16 kHz)")
        let lines = text.isEmpty ? [] : [TranscriptLine(start: start, end: end, text: text)]
        if window.commit {
            let correctedLines = lines.map { TranscriptLine(start: $0.start, end: $0.end, text: CourseVocabulary.shared.correctFinalText($0.text)) }
            session?.appendConfirmed(correctedLines)
            deviceAudioProcessedSamples += window.owned.count
            if sessionStorageMode == .saveTranscript {
                persist()
            }
            provisional = []; previousHypothesis = []
            if let line = correctedLines.first {
                CaptionFeed.shared.update(original: caption, translation: validTranslatedDraft)
                LiveActivityCoordinator.shared.updateTranscript(original: line.text, translation: validTranslatedDraft)
            }
        } else {
            provisional = lines
        }
    }

    private func decodeDeviceAudioWhisper() async throws {
        deviceAudioBufferLock.lock()
        let samples = deviceAudioBuffer
        let bufferStart = deviceAudioBufferStartOffset
        deviceAudioBufferLock.unlock()
        let localStart = max(0, deviceAudioProcessedSamples - bufferStart)
        let available = samples.count - localStart
        guard available >= 64_000 else { return }
        let count = min(128_000, available)
        let input = Array(samples[localStart..<(localStart + count)])
        let offset = Double(deviceAudioProcessedSamples) / 16_000
        let decoded = try await engine.transcribe(samples: input, offset: offset, language: language,
            vocabulary: vocabulary, final: true) { [weak self] text, _ in
                Task { @MainActor in self?.liveDraft = text }
            }
        try Task.checkCancellation()
        guard isRecording, usesWhisper else { return }
        let corrected = decoded.lines.map { TranscriptLine(start: $0.start, end: $0.end,
            text: CourseVocabulary.shared.correctFinalText($0.text), words: $0.words) }
        session?.appendConfirmed(corrected)
        deviceAudioProcessedSamples += count
        liveDraft = ""; provisional = []
        if let line = corrected.last {
            CaptionFeed.shared.update(original: caption, translation: validTranslatedDraft)
            LiveActivityCoordinator.shared.updateTranscript(original: line.text, translation: validTranslatedDraft)
        }
    }

    private func fail(_ context: String, _ error: Error) {
        status = context
        errorMessage = context + "\n\n" + error.localizedDescription
    }
}

extension LectureController: DeviceAudioCaptureDelegate {
    func deviceAudioDidOutput(samples: [Float], level: Float) {
        guard isRecording, audioSource == .deviceAudio else { return }
        self.level = level
        self.deviceAudioDuration += Double(samples.count) / 16000

        if usesAppleSpeech {
            Task { [weak self] in
                try? await self?.appleSpeech?.append(samples)
            }
        }
        deviceAudioBufferLock.lock()
        deviceAudioBuffer.append(contentsOf: samples)
        let maxBufferSize = 30 * 16000
        if deviceAudioBuffer.count > maxBufferSize {
            let overflow = deviceAudioBuffer.count - maxBufferSize
            deviceAudioBuffer.removeFirst(overflow)
            deviceAudioBufferStartOffset += overflow
        }
        deviceAudioBufferLock.unlock()
    }

    func deviceAudioDidEncounterError(_ error: Error) {
        stopCapture()
        fail(L10n.tr("裝置聲音擷取失敗。", "Device audio capture failed."), error)
    }

    func deviceAudioDidStopBySystem() {
        stopCapture()
        status = L10n.tr("裝置聲音擷取已被系統中斷。", "Device audio capture was stopped by the system.")
    }
}

