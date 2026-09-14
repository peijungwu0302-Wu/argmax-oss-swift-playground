import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class LectureAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var activePartIndex: Int = 0
    @Published var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var session: LectureSession?
    private var store: SessionStore?
    private var timer: Timer?

    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.enableRate = true
        player?.rate = rate
    }

    func setup(session: LectureSession, store: SessionStore) {
        self.session = session
        self.store = store
        self.duration = session.duration
        self.currentTime = 0
        self.isPlaying = false
        self.activePartIndex = 0
        self.playbackRate = 1.0
        stop()
    }

    func play() {
        guard duration > 0 else { return }
        if player == nil {
            prepareAndPlay(at: currentTime, autoPlay: true)
        } else {
            player?.enableRate = true
            player?.rate = playbackRate
            player?.play()
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: Double) {
        let clamped = max(0, min(duration, time))
        currentTime = clamped
        prepareAndPlay(at: clamped, autoPlay: isPlaying)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    private func prepareAndPlay(at time: Double, autoPlay: Bool = true) {
        guard let session, let store, !session.parts.isEmpty else { return }
        var targetIndex = 0
        for (i, part) in session.parts.enumerated() {
            let partDur = Double(part.sampleCount) / 16000.0
            if time >= part.offset && time < part.offset + partDur {
                targetIndex = i
                break
            }
            if i == session.parts.count - 1 {
                targetIndex = i
            }
        }

        let part = session.parts[targetIndex]
        let localTime = max(0, time - part.offset)
        activePartIndex = targetIndex

        Task {
            do {
                let url = store.audioURL(session, part)
                let playable = try StoredAudio.playable(url, samples: part.sampleCount)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)

                let nextPlayer = try AVAudioPlayer(contentsOf: playable)
                nextPlayer.enableRate = true
                nextPlayer.rate = self.playbackRate
                nextPlayer.delegate = self
                nextPlayer.currentTime = localTime
                self.player?.stop()
                self.player = nextPlayer

                if autoPlay {
                    nextPlayer.play()
                    self.isPlaying = true
                    self.startTimer()
                } else {
                    self.isPlaying = false
                }
            } catch {
                self.isPlaying = false
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentTime()
            }
        }
    }

    private func updateCurrentTime() {
        guard let player, isPlaying, let session, activePartIndex < session.parts.count else { return }
        let part = session.parts[activePartIndex]
        currentTime = part.offset + player.currentTime
        if currentTime >= duration {
            currentTime = duration
            pause()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard let session = self.session else { return }
            let nextIndex = self.activePartIndex + 1
            if nextIndex < session.parts.count {
                let nextPart = session.parts[nextIndex]
                self.prepareAndPlay(at: nextPart.offset, autoPlay: true)
            } else {
                self.currentTime = self.duration
                self.pause()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}

struct LectureDetailView: View {
    @ObservedObject var controller: LectureController
    let session: LectureSession

    @StateObject private var player = LectureAudioPlayer()
    @State private var selectedVersionID: UUID?
    @State private var displayMode: PiPDisplayMode = .bilingual
    @State private var search = ""
    @State private var showRetranscribe = false
    @State private var showCompare = false
    @State private var showRename = false
    @State private var newTitle = ""
    @State private var showDeleteLectureAlert = false
    @State private var showDeleteVersionAlert = false
    @State private var sharedFile: SharedFile?
    @State private var followAudio = true
    @State private var editingLine: TranscriptLine?
    @State private var bookmarkingTime: Double?
    @State private var bookmarkNote = ""
    @Environment(\.dismiss) private var dismiss

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
    private let ink = Color(red: 0.20, green: 0.19, blue: 0.16)
    private let gold = Color(red: 0.59, green: 0.40, blue: 0.08)
    private let red = Color(red: 0.69, green: 0.18, blue: 0.14)

    private var currentSession: LectureSession {
        controller.history.first(where: { $0.id == session.id }) ?? session
    }

    private var currentVersion: TranscriptVersion? {
        if let id = selectedVersionID, let v = currentSession.transcriptVersions.first(where: { $0.id == id }) {
            return v
        }
        return currentSession.preferredVersion ?? currentSession.transcriptVersions.first
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    headerSection
                    Divider()
                    playerSection
                    Divider()
                    versionPickerSection
                    Divider()

                    if let version = currentVersion {
                        transcriptView(version: version, isWide: geometry.size.width >= 700, scrollProxy: scrollProxy)
                    } else {
                        emptyTranscriptView
                    }
                }
            }
        }
        .background(paper)
        .navigationTitle(currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(L10n.tr("重新轉錄這堂課", "Retranscribe Lecture")) { showRetranscribe = true }
                    if currentSession.transcriptVersions.count >= 2 {
                        Button(L10n.tr("比較逐字稿版本", "Compare Versions")) { showCompare = true }
                    }
                    Divider()
                    Menu(L10n.tr("匯出逐字稿", "Export Transcript")) {
                        ForEach(TranscriptFormat.allCases) { format in
                            Button(L10n.tr("匯出 \(format.rawValue)", "Export \(format.rawValue)")) {
                                if let url = controller.export(format, version: currentVersion) {
                                    sharedFile = SharedFile(url: url)
                                }
                            }
                        }
                    }
                    Button(L10n.tr("分享原始錄音", "Share Original Audio")) {
                        Task { await shareAudio() }
                    }
                    Divider()
                    Button(L10n.tr("重新命名", "Rename")) {
                        newTitle = currentSession.title
                        showRename = true
                    }
                    Button(L10n.tr("載入此課堂繼續錄音", "Load Lecture & Continue")) {
                        controller.open(currentSession)
                        dismiss()
                    }
                    Divider()
                    Button(L10n.tr("刪除這堂課", "Delete Lecture"), role: .destructive) {
                        showDeleteLectureAlert = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            if let store = try? SessionStore() {
                player.setup(session: currentSession, store: store)
            }
            selectedVersionID = currentSession.preferredVersionID ?? currentSession.transcriptVersions.first?.id
        }
        .onDisappear {
            player.stop()
        }
        .sheet(isPresented: $showRetranscribe) {
            RetranscribeSheet(controller: controller, session: currentSession) { newVer in
                selectedVersionID = newVer.id
            }
        }
        .sheet(isPresented: $showCompare) {
            TranscriptCompareSheet(session: currentSession, onSeek: { time in
                player.seek(to: time)
                player.play()
            })
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(url: file.url)
        }
        .sheet(item: $editingLine) { line in
            LineEditor(line: line) { newText in
                if let vID = currentVersion?.id {
                    controller.updateVersionLine(sessionID: currentSession.id, versionID: vID, lineID: line.id, text: newText)
                }
            }
        }
        .alert(L10n.tr("加入重點標記", "Add Bookmark"), isPresented: Binding(get: { bookmarkingTime != nil }, set: { if !$0 { bookmarkingTime = nil } })) {
            TextField(L10n.tr("簡短註記（可留白）", "Short note (optional)"), text: $bookmarkNote)
            Button(L10n.tr("加入", "Add")) {
                if let t = bookmarkingTime {
                    controller.bookmark(sessionID: currentSession.id, note: bookmarkNote, at: t)
                    bookmarkNote = ""
                    bookmarkingTime = nil
                }
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) { bookmarkingTime = nil }
        } message: {
            Text(L10n.tr("時間點：", "Time: ") + TranscriptExport.clock(bookmarkingTime ?? 0))
        }
        .alert(L10n.tr("重新命名課堂", "Rename Lecture"), isPresented: $showRename) {
            TextField(L10n.tr("課堂名稱", "Lecture Name"), text: $newTitle)
            Button(L10n.tr("儲存", "Save")) {
                controller.renameLecture(currentSession.id, title: newTitle)
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L10n.tr("刪除整堂課？", "Delete entire lecture?"), isPresented: $showDeleteLectureAlert, titleVisibility: .visible) {
            Button(L10n.tr("刪除錄音與所有逐字稿", "Delete audio and all transcripts"), role: .destructive) {
                player.stop()
                controller.deleteLecture(currentSession.id)
                dismiss()
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("將永久刪除「\(currentSession.title)」的原始錄音與所有逐字稿版本，無法復原。", "Will permanently delete audio and all transcripts for \"\(currentSession.title)\"."))
        }
        .confirmationDialog(L10n.tr("刪除逐字稿版本？", "Delete transcript version?"), isPresented: $showDeleteVersionAlert, titleVisibility: .visible) {
            Button(L10n.tr("刪除此版本（保留錄音）", "Delete this version (keep audio)"), role: .destructive) {
                if let id = currentVersion?.id {
                    controller.deleteTranscriptVersion(sessionID: currentSession.id, versionID: id)
                    selectedVersionID = currentSession.preferredVersionID ?? currentSession.transcriptVersions.first?.id
                }
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("將刪除「\(currentVersion?.name ?? "")」，原始錄音與其他版本均不受影響。", "Will delete \"\(currentVersion?.name ?? "")\"; original audio remains unaffected."))
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    newTitle = currentSession.title
                    showRename = true
                } label: {
                    HStack(spacing: 6) {
                        Text(currentSession.title)
                            .font(.title3.bold())
                            .foregroundStyle(ink)
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                Text(L10n.tr("\(currentSession.transcriptVersions.count) 個逐字稿版本", "\(currentSession.transcriptVersions.count) Versions"))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(gold.opacity(0.15))
                    .foregroundStyle(gold)
                    .clipShape(Capsule())
            }
            HStack(spacing: 12) {
                Label(currentSession.createdAt.formatted(date: .numeric, time: .shortened), systemImage: "calendar")
                Label(TranscriptExport.clock(currentSession.duration), systemImage: "clock")
                Label(controller.audioSize(currentSession), systemImage: "waveform")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var playerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(TranscriptExport.clock(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(gold)
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(0.1, player.duration)
                )
                .tint(gold)
                Text(TranscriptExport.clock(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }
                .disabled(player.duration == 0)

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(gold)
                }
                .disabled(player.duration == 0)

                Button {
                    player.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title3)
                }
                .disabled(player.duration == 0)

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button {
                            player.setRate(Float(r))
                        } label: {
                            HStack {
                                Text(String(format: "%.2fx", r))
                                if abs(player.playbackRate - Float(r)) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", player.playbackRate))
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(gold.opacity(0.15))
                        .foregroundStyle(gold)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.4))
    }

    private var versionPickerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(currentSession.transcriptVersions) { v in
                        Button {
                            selectedVersionID = v.id
                        } label: {
                            HStack {
                                if v.id == currentVersion?.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(v.name)
                                if v.isPreferred {
                                    Text("（\(L10n.tr("預設", "Default"))）")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(gold)
                        Text(currentVersion?.name ?? L10n.tr("選擇逐字稿版本", "Select Transcript"))
                            .font(.subheadline.bold())
                            .foregroundStyle(ink)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let tvs = currentVersion?.translationVersions, tvs.count > 1 {
                    Menu {
                        ForEach(tvs) { tv in
                            Button {
                                if let vID = currentVersion?.id {
                                    controller.setPreferredTranslationVersion(sessionID: currentSession.id, versionID: vID, translationVersionID: tv.id)
                                }
                            } label: {
                                HStack {
                                    if tv.id == currentVersion?.activeTranslationVersion?.id {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(tv.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "character.bubble.fill")
                                .foregroundStyle(gold)
                            Text(currentVersion?.activeTranslationVersion?.name ?? L10n.tr("翻譯版本", "Translation"))
                                .font(.caption.bold())
                                .foregroundStyle(ink)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Spacer()

                if let v = currentVersion {
                    if !v.isPreferred {
                        Button(L10n.tr("設為預設", "Set as Default")) {
                            controller.setPreferredVersion(sessionID: currentSession.id, versionID: v.id)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    if currentSession.transcriptVersions.count > 1 {
                        Button(role: .destructive) {
                            showDeleteVersionAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Picker(L10n.tr("檢視模式", "View Mode"), selection: $displayMode) {
                Text(L10n.tr("雙語對照", "Bilingual")).tag(PiPDisplayMode.bilingual)
                Text(L10n.tr("僅中文", "Chinese Only")).tag(PiPDisplayMode.chineseOnly)
                Text(L10n.tr("僅原文", "Original Only")).tag(PiPDisplayMode.originalOnly)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.2))
    }

    private func transcriptView(version: TranscriptVersion, isWide: Bool, scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField(L10n.tr("搜尋此版本逐字稿", "Search transcript"), text: $search)
                Toggle(L10n.tr("跟隨播放", "Follow Playback"), isOn: $followAudio).font(.caption).fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.5))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let translatedMap = Dictionary(uniqueKeysWithValues: (version.translations ?? []).map { ($0.id, $0) })
                    ForEach(version.lines) { line in
                        if search.isEmpty || line.text.localizedCaseInsensitiveContains(search) {
                            let isPlayingCurrent = player.isPlaying && player.currentTime >= line.start && player.currentTime <= line.end
                            let translated = translatedMap[line.id]

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button {
                                        player.seek(to: line.start)
                                        player.play()
                                    } label: {
                                        Label(TranscriptExport.clock(line.start), systemImage: "play.circle")
                                            .font(.caption.monospacedDigit().bold())
                                            .foregroundStyle(gold)
                                    }
                                    .buttonStyle(.borderless)

                                    let label = currentSession.speakerLabel(line)
                                    if !label.isEmpty {
                                        Text(label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }

                                switch displayMode {
                                case .bilingual:
                                    Text(line.text)
                                        .font(.body)
                                        .foregroundStyle(ink)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                    if let tr = translated {
                                        Text(tr.text)
                                            .font(.callout)
                                            .foregroundStyle(Color(red: 0.65, green: 0.45, blue: 0.10))
                                            .lineSpacing(3)
                                            .textSelection(.enabled)
                                            .padding(.leading, 8)
                                            .padding(.vertical, 2)
                                            .background(gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                case .chineseOnly:
                                    if let tr = translated {
                                        Text(tr.text)
                                            .font(.body)
                                            .foregroundStyle(Color(red: 0.65, green: 0.45, blue: 0.10))
                                            .lineSpacing(4)
                                            .textSelection(.enabled)
                                    } else {
                                        Text(line.text)
                                            .font(.body)
                                            .foregroundStyle(ink)
                                            .lineSpacing(4)
                                            .textSelection(.enabled)
                                    }
                                case .originalOnly:
                                    Text(line.text)
                                        .font(.body)
                                        .foregroundStyle(ink)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                }
                            }
                            .id(line.id)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isPlayingCurrent ? gold.opacity(0.18) : Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.start)
                                player.play()
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = line.text
                                } label: {
                                    Label(L10n.tr("複製原文", "Copy Original"), systemImage: "doc.on.doc")
                                }
                                if let tr = translated {
                                    Button {
                                        UIPasteboard.general.string = tr.text
                                    } label: {
                                        Label(L10n.tr("複製翻譯", "Copy Translation"), systemImage: "doc.on.doc.fill")
                                    }
                                }
                                Button {
                                    editingLine = line
                                } label: {
                                    Label(L10n.tr("編輯逐字稿", "Edit Transcript"), systemImage: "pencil")
                                }
                                Button {
                                    bookmarkingTime = line.start
                                } label: {
                                    Label(L10n.tr("加入重點標記", "Add Bookmark"), systemImage: "bookmark")
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: player.currentTime) { time in
                if followAudio, player.isPlaying {
                    if let activeLine = version.lines.first(where: { time >= $0.start && time <= $0.end }) {
                        withAnimation {
                            scrollProxy.scrollTo(activeLine.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var emptyTranscriptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 44))
                .foregroundStyle(gold)
            Text(L10n.tr("這堂課尚未建立逐字稿", "No transcript created for this lecture"))
                .font(.headline)
            Text(L10n.tr("原始錄音已安全保存。點擊下方按鈕使用 Whisper v3 產生逐字稿。", "Original audio is safely saved. Tap below to generate a transcript with Whisper v3."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.tr("開始重新轉錄", "Start Retranscription")) {
                showRetranscribe = true
            }
            .buttonStyle(.borderedProminent)
            .tint(gold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func shareAudio() async {
        guard let store = try? SessionStore(), let firstPart = currentSession.parts.first else { return }
        do {
            let url = store.audioURL(currentSession, firstPart)
            let playable = try await Task.detached(priority: .userInitiated) {
                try StoredAudio.playable(url, samples: firstPart.sampleCount)
            }.value
            sharedFile = SharedFile(url: playable)
        } catch {
            controller.errorMessage = "準備音訊分享失敗：\(error.localizedDescription)"
        }
    }
}

struct RetranscribeSheet: View {
    @ObservedObject var controller: LectureController
    let session: LectureSession
    let onCompleted: (TranscriptVersion) -> Void

    @State private var engine: TranscriptEngine = .whisper
    @State private var model: String = SpeechModel.turbo.rawValue
    @State private var language: String = "mixed"
    @State private var vocabulary: String = ""
    @State private var autoTranslate: Bool = true
    @State private var isRunning: Bool = false
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.tr("會為「\(session.title)」新增一個全新的逐字稿版本。原逐字稿與唯一原始錄音不會被刪除或複製。", "Will create a new transcript version for \"\(session.title)\". Original recording and existing transcripts will not be deleted or duplicated."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.tr("辨識引擎", "Recognition Engine")) {
                    Picker(L10n.tr("引擎", "Engine"), selection: $engine) {
                        Text(L10n.tr("Whisper v3（建議）", "Whisper v3 (Recommended)")).tag(TranscriptEngine.whisper)
                        Text("SenseVoice Core ML").tag(TranscriptEngine.sensevoice)
                    }
                    .pickerStyle(.segmented)
                }

                if engine == .whisper {
                    Section(L10n.tr("Whisper 模型", "Whisper Model")) {
                        Picker(L10n.tr("模型大小", "Model Size"), selection: $model) {
                            ForEach(SpeechModel.allCases) { m in
                                Text(m.title).tag(m.rawValue)
                            }
                        }
                    }

                    Section(L10n.tr("課堂語言", "Lecture Language")) {
                        Picker(L10n.tr("語言模式", "Language Mode"), selection: $language) {
                            Text(L10n.tr("中英夾雜", "Mixed Chinese / English")).tag("mixed")
                            Text(L10n.tr("中文", "Chinese")).tag("zh")
                            Text(L10n.tr("英文", "English")).tag("en")
                            Text(L10n.tr("自動偵測", "Auto Detect")).tag("auto")
                        }
                    }

                    Section(L10n.tr("課堂專有名詞提示", "Vocabulary / Terminology Hints")) {
                        TextField(L10n.tr("例如：CRISPR, Cas9, gene editing", "e.g. CRISPR, Cas9, gene editing"), text: $vocabulary, axis: .vertical)
                            .lineLimit(3...5)
                        Text(L10n.tr("輸入這堂課常用的英文專業術語或人名，有助提升 WhisperKit 辨識準確率。", "Enter key terminology or names to improve accuracy."))
                            .font(.caption)
                    }
                } else {
                    Section(L10n.tr("SenseVoice 語言", "SenseVoice Language")) {
                        Picker(L10n.tr("語言", "Language"), selection: $language) {
                            Text(L10n.tr("自動", "Auto")).tag("auto")
                            Text(L10n.tr("中文為主", "Chinese Primary")).tag("mixed")
                            Text(L10n.tr("英文為主", "English Primary")).tag("mixed-en")
                        }
                    }
                }

                Section(L10n.tr("翻譯選項", "Translation Options")) {
                    Toggle(L10n.tr("完成後自動翻譯成繁體中文", "Automatically translate to Traditional Chinese"), isOn: $autoTranslate)
                }

                if isRunning {
                    Section(L10n.tr("轉錄進度", "Transcription Progress")) {
                        VStack(spacing: 8) {
                            ProgressView(value: controller.progress ?? 0.0)
                            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("重新轉錄這堂課", "Retranscribe Lecture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? L10n.tr("取消", "Cancel") : L10n.tr("關閉", "Close")) {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("開始轉錄", "Start Transcription")) {
                        startRetranscribe()
                    }
                    .disabled(isRunning)
                }
            }
        }
    }

    private func startRetranscribe() {
        isRunning = true
        task = Task {
            do {
                let ver = try await controller.retranscribe(
                    session: session,
                    engine: engine,
                    model: model,
                    language: language,
                    vocabulary: vocabulary,
                    autoTranslate: autoTranslate
                )
                isRunning = false
                onCompleted(ver)
                dismiss()
            } catch is CancellationError {
                isRunning = false
            } catch {
                isRunning = false
                controller.errorMessage = "重新轉錄失敗：\(error.localizedDescription)"
            }
        }
    }
}

struct TranscriptCompareSheet: View {
    let session: LectureSession
    let onSeek: (Double) -> Void

    @State private var versionAID: UUID?
    @State private var versionBID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var versionA: TranscriptVersion? {
        session.transcriptVersions.first(where: { $0.id == versionAID }) ?? session.transcriptVersions.first
    }

    private var versionB: TranscriptVersion? {
        if let id = versionBID, let v = session.transcriptVersions.first(where: { $0.id == id }) {
            return v
        }
        if session.transcriptVersions.count >= 2 {
            return session.transcriptVersions[1]
        }
        return session.transcriptVersions.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pickerHeader
                Divider()
                GeometryReader { geo in
                    if geo.size.width >= 700 {
                        HStack(spacing: 0) {
                            if let a = versionA {
                                versionColumn(version: a, title: "版本 A")
                                    .frame(maxWidth: .infinity)
                            }
                            Divider()
                            if let b = versionB {
                                versionColumn(version: b, title: "版本 B")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            if let a = versionA {
                                versionColumn(version: a, title: "版本 A")
                                    .frame(maxHeight: .infinity)
                            }
                            Divider()
                            if let b = versionB {
                                versionColumn(version: b, title: "版本 B")
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("比較逐字稿版本", "Compare Transcript Versions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done")) { dismiss() }
                }
            }
            .onAppear {
                if versionAID == nil {
                    versionAID = session.transcriptVersions.first?.id
                }
                if versionBID == nil, session.transcriptVersions.count >= 2 {
                    versionBID = session.transcriptVersions[1].id
                }
            }
        }
    }

    private var pickerHeader: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(L10n.tr("版本 A", "Version A")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.tr("版本 A", "Version A"), selection: Binding(
                    get: { versionAID ?? session.transcriptVersions.first?.id ?? UUID() },
                    set: { versionAID = $0 }
                )) {
                    ForEach(session.transcriptVersions) { v in
                        Text(v.name).tag(v.id)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(L10n.tr("版本 B", "Version B")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.tr("版本 B", "Version B"), selection: Binding(
                    get: { versionBID ?? (session.transcriptVersions.count > 1 ? session.transcriptVersions[1].id : session.transcriptVersions.first?.id ?? UUID()) },
                    set: { versionBID = $0 }
                )) {
                    ForEach(session.transcriptVersions) { v in
                        Text(v.name).tag(v.id)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func versionColumn(version: TranscriptVersion, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(version.name).font(.headline)
                Spacer()
                Text(version.engine.displayName).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(version.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                onSeek(line.start)
                            } label: {
                                Text("[\(TranscriptExport.clock(line.start))]")
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(Color(red: 0.59, green: 0.40, blue: 0.08))
                            }
                            Text(line.text)
                                .font(.body)
                                .textSelection(.enabled)
                            if let trans = version.translation(for: line) {
                                Text(trans.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}
