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
                    Button("重新轉錄這堂課") { showRetranscribe = true }
                    if currentSession.transcriptVersions.count >= 2 {
                        Button("比較逐字稿版本") { showCompare = true }
                    }
                    Divider()
                    Menu("匯出逐字稿") {
                        ForEach(TranscriptFormat.allCases) { format in
                            Button("匯出 \(format.rawValue)") {
                                if let url = controller.export(format, version: currentVersion) {
                                    sharedFile = SharedFile(url: url)
                                }
                            }
                        }
                    }
                    Button("分享原始錄音") {
                        Task { await shareAudio() }
                    }
                    Divider()
                    Button("重新命名") {
                        newTitle = currentSession.title
                        showRename = true
                    }
                    Button("載入此課堂繼續錄音") {
                        controller.open(currentSession)
                        dismiss()
                    }
                    Divider()
                    Button("刪除這堂課", role: .destructive) {
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
        .alert("加入重點標記", isPresented: Binding(get: { bookmarkingTime != nil }, set: { if !$0 { bookmarkingTime = nil } })) {
            TextField("簡短註記（可留白）", text: $bookmarkNote)
            Button("加入") {
                if let t = bookmarkingTime {
                    controller.bookmark(sessionID: currentSession.id, note: bookmarkNote, at: t)
                    bookmarkNote = ""
                    bookmarkingTime = nil
                }
            }
            Button("取消", role: .cancel) { bookmarkingTime = nil }
        } message: {
            Text("時間點：\(TranscriptExport.clock(bookmarkingTime ?? 0))")
        }
        .alert("重新命名課堂", isPresented: $showRename) {
            TextField("課堂名稱", text: $newTitle)
            Button("儲存") {
                controller.renameLecture(currentSession.id, title: newTitle)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("刪除整堂課？", isPresented: $showDeleteLectureAlert, titleVisibility: .visible) {
            Button("刪除錄音與所有逐字稿", role: .destructive) {
                player.stop()
                controller.deleteLecture(currentSession.id)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("將永久刪除「\(currentSession.title)」的原始錄音與所有逐字稿版本，無法復原。")
        }
        .confirmationDialog("刪除逐字稿版本？", isPresented: $showDeleteVersionAlert, titleVisibility: .visible) {
            Button("刪除此版本（保留錄音）", role: .destructive) {
                if let id = currentVersion?.id {
                    controller.deleteTranscriptVersion(sessionID: currentSession.id, versionID: id)
                    selectedVersionID = currentSession.preferredVersionID ?? currentSession.transcriptVersions.first?.id
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("將刪除「\(currentVersion?.name ?? "")」，原始錄音與其他版本均不受影響。")
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
                Text("\(currentSession.transcriptVersions.count) 個逐字稿版本")
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
            HStack {
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
                                    Text("（預設）")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(gold)
                        Text(currentVersion?.name ?? "選擇逐字稿版本")
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

                Spacer()

                if let v = currentVersion {
                    if !v.isPreferred {
                        Button("設為預設") {
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

            Picker("檢視模式", selection: $displayMode) {
                Text("雙語對照").tag(PiPDisplayMode.bilingual)
                Text("僅中文").tag(PiPDisplayMode.chineseOnly)
                Text("僅原文").tag(PiPDisplayMode.originalOnly)
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
                TextField("搜尋此版本逐字稿", text: $search)
                Toggle("跟隨播放", isOn: $followAudio).font(.caption).fixedSize()
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
                                    Label("複製原文", systemImage: "doc.on.doc")
                                }
                                if let tr = translated {
                                    Button {
                                        UIPasteboard.general.string = tr.text
                                    } label: {
                                        Label("複製翻譯", systemImage: "doc.on.doc.fill")
                                    }
                                }
                                Button {
                                    editingLine = line
                                } label: {
                                    Label("編輯逐字稿", systemImage: "pencil")
                                }
                                Button {
                                    bookmarkingTime = line.start
                                } label: {
                                    Label("加入重點標記", systemImage: "bookmark")
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
            Text("這堂課尚未建立逐字稿")
                .font(.headline)
            Text("原始錄音已安全保存。點擊下方按鈕使用 Whisper v3 產生逐字稿。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("開始重新轉錄") {
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
                    Text("會為「\(session.title)」新增一個全新的逐字稿版本。原逐字稿與唯一原始錄音不會被刪除或複製。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("辨識引擎") {
                    Picker("引擎", selection: $engine) {
                        Text("Whisper v3（建議）").tag(TranscriptEngine.whisper)
                        Text("SenseVoice Core ML").tag(TranscriptEngine.sensevoice)
                    }
                    .pickerStyle(.segmented)
                }

                if engine == .whisper {
                    Section("Whisper 模型") {
                        Picker("模型大小", selection: $model) {
                            ForEach(SpeechModel.allCases) { m in
                                Text(m.title).tag(m.rawValue)
                            }
                        }
                    }

                    Section("課堂語言") {
                        Picker("語言模式", selection: $language) {
                            Text("中英夾雜").tag("mixed")
                            Text("中文").tag("zh")
                            Text("英文").tag("en")
                            Text("自動偵測").tag("auto")
                        }
                    }

                    Section("課堂專有名詞提示") {
                        TextField("例如：CRISPR, Cas9, gene editing", text: $vocabulary, axis: .vertical)
                            .lineLimit(3...5)
                        Text("輸入這堂課常用的英文專業術語或人名，有助提升 WhisperKit 辨識準確率。")
                            .font(.caption)
                    }
                } else {
                    Section("SenseVoice 語言") {
                        Picker("語言", selection: $language) {
                            Text("自動").tag("auto")
                            Text("中文為主").tag("mixed")
                            Text("英文為主").tag("mixed-en")
                        }
                    }
                }

                Section("翻譯選項") {
                    Toggle("完成後自動翻譯成繁體中文", isOn: $autoTranslate)
                }

                if isRunning {
                    Section("轉錄進度") {
                        VStack(spacing: 8) {
                            ProgressView(value: controller.progress ?? 0.0)
                            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("重新轉錄這堂課")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? "取消" : "關閉") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始轉錄") {
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
            .navigationTitle("比較逐字稿版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
                Text("版本 A").font(.caption).foregroundStyle(.secondary)
                Picker("版本 A", selection: Binding(
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
                Text("版本 B").font(.caption).foregroundStyle(.secondary)
                Picker("版本 B", selection: Binding(
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
