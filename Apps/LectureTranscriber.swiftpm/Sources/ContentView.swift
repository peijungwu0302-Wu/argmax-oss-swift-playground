import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct ContentView: View {
    @ObservedObject var controller: LectureController
    @State private var showHistory = false
    @State private var showImport = false
    @State private var importAfterHistory = false
    @State private var showAudio = false
    @State private var showBookmark = false
    @State private var showSettings = false
    @State private var showMinutes = false
    @State private var bookmarkNote = ""
    @State private var sharedFile: SharedFile?
    @State private var editedLine: TranscriptLine?
    @State private var followLatest = true
    @State private var pendingDeletion: LectureSession?
    @State private var historySearch = ""
    @State private var renamingSession: LectureSession?
    @State private var renameTitle = ""
    @State private var showRenameAlert = false
    @State private var captionMode = true
    @State private var compactMode = false
    @State private var pipPreview = false
    @State private var reviewedLine: TranscriptLine?
    @State private var showSpeakers = false
    @StateObject private var pip = CaptionPiP()
    @StateObject private var updates = AppUpdates()
    @AppStorage("automaticallyCheckUpdates") private var automaticallyCheckUpdates = true
    @AppStorage("captionFontSize") private var captionFontSize = 25.0
    @AppStorage("translationFontSize") private var translationFontSize = 20.0
    @AppStorage("transcriptFontSize") private var transcriptFontSize = 17.0
    private let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
    private let ink = Color(red: 0.20, green: 0.19, blue: 0.16)
    private let gold = Color(red: 0.59, green: 0.40, blue: 0.08)
    private let red = Color(red: 0.69, green: 0.18, blue: 0.14)

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if pipPreview {
                    pipWorkspace
                } else if compactMode {
                    compactWorkspace
                } else {
                ScrollView {
                    VStack(spacing: 20) {
                        recordingHeader
                        translationCard
                        HStack {
                            Image(systemName: "magnifyingglass")
                            TextField("搜尋逐字稿", text: $controller.search)
                            Toggle("跟隨最新", isOn: $followLatest).font(.caption).fixedSize()
                        }.foregroundStyle(.secondary)
                        let height = max(280, geometry.size.height - 350)
                        if geometry.size.width >= 700 && controller.translationEnabled {
                            HStack(alignment: .top, spacing: 20) {
                                transcriptPane(translated: false).frame(maxWidth: .infinity)
                                transcriptPane(translated: true).frame(maxWidth: .infinity)
                            }.frame(height: height)
                        } else {
                            transcriptPane(translated: false).frame(height: height)
                            if controller.translationEnabled {
                                transcriptPane(translated: true).frame(height: 300)
                            }
                        }
                        Text(controller.backgroundDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, geometry.size.width >= 700 ? 32 : 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                }
                }
            }
            .background(paper)
            .foregroundStyle(ink)
            .background(CompactWindowSizing(compact: compactMode || pipPreview).frame(width: 0, height: 0))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !compactMode && !pipPreview && captionMode && (controller.isRecording || !controller.caption.isEmpty) { captionPanel }
                    if !compactMode && !pipPreview { bottomBar }
                }
            }
            .navigationTitle(compactMode ? "字幕" : "錄音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(compactMode || pipPreview ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { controller.reloadHistory(); showHistory = true } label: {
                        Label("歷史紀錄", systemImage: "books.vertical")
                    }.disabled(!controller.canManageSessions)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { compactMode.toggle() } label: {
                        Image(systemName: compactMode ? "arrow.up.left.and.arrow.down.right" : "rectangle.inset.filled")
                    }.accessibilityLabel(compactMode ? "完整畫面" : "精簡字幕")
                    if !compactMode {
                    Button { captionMode.toggle() } label: {
                        Image(systemName: captionMode ? "captions.bubble.fill" : "captions.bubble")
                    }.accessibilityLabel("字幕模式")
                    Button { controller.newLecture() } label: { Label("新課堂", systemImage: "square.and.pencil") }
                        .disabled(!controller.canManageSessions)
                    }
                    Button { showSettings = true } label: { Label("錄音設定", systemImage: "slider.horizontal.3") }
                    Menu {
                        Button("子母畫面字幕（beta）") { pipPreview = true; controller.pipEnabled = true }
                        Button("講者分析與命名（beta）") { showSpeakers = true }
                        if controller.session?.previousLines != nil { Button("復原最近一次稿件替換") { controller.undoReview() } }
                        Button("錄音檔案：播放與分享") { showAudio = true }
                        Button("SenseVoice 錄後重新轉錄（另存新課堂）") {
                            Task { await controller.retranscribeRecording() }
                        }.disabled(controller.session?.parts.contains { $0.sampleCount > 0 } != true)
                        ForEach(TranscriptFormat.allCases) { format in
                            Button("匯出 \(format.rawValue)") {
                                if let url = controller.export(format) { sharedFile = SharedFile(url: url) }
                            }
                        }
                        if controller.session?.minutes != nil {
                            Button("查看會議紀錄") { showMinutes = true }
                        }
                    } label: { Label("匯出", systemImage: "square.and.arrow.up") }
                    .disabled(controller.session == nil || !controller.canManageSessions)
                }
            }
            .tint(gold)
            .modifier(LiveTranslationModifier(controller: controller))
            .sheet(isPresented: $showHistory, onDismiss: { if importAfterHistory { importAfterHistory = false; showImport = true } }) { historySheet }
            .sheet(isPresented: $showAudio) {
                if let lecture = controller.session { NavigationStack { LectureDetailView(controller: controller, session: lecture).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showAudio = false } } } } }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio, .data]) { result in
                switch result {
                case .success(let url): Task { await controller.importAudio(url) }
                case .failure(let error): controller.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(isPresented: $showMinutes) { minutesSheet }
            .sheet(isPresented: $showSpeakers) { SpeakerSettingsView(controller: controller) }
            .sheet(item: $reviewedLine) { line in
                if let id = controller.session?.id { TranscriptReviewView(controller: controller, line: line, sessionID: id) }
            }
            .sheet(item: $sharedFile) { file in ShareSheet(url: file.url) }
            .sheet(item: $editedLine) { line in LineEditor(line: line) { controller.updateLine(line.id, text: $0) } }
            .alert("重點標記", isPresented: $showBookmark) {
                TextField("簡短註記（可留白）", text: $bookmarkNote)
                Button("加入") { controller.bookmark(bookmarkNote); bookmarkNote = "" }
                Button("取消", role: .cancel) {}
            } message: { Text("標記會使用目前的錄音時間。") }
            .alert("需要留意", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
                Button("知道了") { controller.errorMessage = nil }
            } message: { Text(controller.errorMessage ?? "") }
        }
        .preferredColorScheme(.light)
        .task { if automaticallyCheckUpdates { await updates.check() } }
        .onChange(of: pip.active) { value in controller.pipActive = value && !pip.paused }
        .onChange(of: pip.paused) { value in controller.pipActive = pip.active && !value }
    }

    private var pipWorkspace: some View {
        VStack(spacing: 6) {
            CaptionPiPPreview(pip: pip, original: controller.caption, translated: controller.translationEnabled ? controller.translationCaption : "",
                              sourceSize: captionFontSize, translationSize: translationFontSize)
                .aspectRatio(3, contentMode: .fit)
            HStack(spacing: 12) {
                Button(pip.active ? "結束子母畫面" : "啟動子母畫面") {
                    if pip.active { pip.stop() } else { pip.start(recording: controller.isRecording) }
                }
                Picker("模式", selection: $pip.displayMode) {
                    ForEach(PiPDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Menu("控制") {
                    Button("完整畫面") { pip.detach(); pipPreview = false; controller.pipEnabled = false; compactMode = false }
                    Button("改用可縮小視窗字幕") { pip.detach(); pipPreview = false; controller.pipEnabled = false; compactMode = true }
                    Button("字級與設定") { showSettings = true }
                    if controller.isRecording { Button("停止並儲存") { Task { await controller.pause() } }.disabled(controller.isBusy) }
                    else { Button(recordLabel) { Task { if controller.session?.hasPendingAudio == true { await controller.recover() } else { await controller.start() } } }.disabled(!controller.canStart && controller.session?.hasPendingAudio != true) }
                }
            }.font(.caption)
            Text(pip.status).font(.caption2)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white)
    }

    private var compactWorkspace: some View {
        ScrollView {
            captionPanel.padding(.trailing, 32)
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("完整畫面") { compactMode = false }
                Button("字級與設定") { showSettings = true }
                Button("子母畫面字幕（beta）") { pipPreview = true; controller.pipEnabled = true }
                Toggle("中文翻譯", isOn: $controller.translationEnabled)
                if controller.isRecording {
                    Button("停止並儲存") { Task { await controller.pause() } }.disabled(controller.isBusy)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.white)
            }.accessibilityLabel("字幕控制")
        }
        .accessibilityIdentifier("compactCaptionWorkspace")
    }

    private var appleLanguageControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Apple 辨識語言", selection: Binding(get: {
                RecognitionLanguage.primary(controller.language) ?? "zh"
            }, set: { controller.selectAppleLanguage($0) })) {
                Text("中文").tag("zh")
                Text("English").tag("en")
            }.pickerStyle(.segmented).accessibilityIdentifier("liveAppleLanguage")
                .disabled(controller.isBusy || controller.isSummarizing || controller.pendingAppleLanguage != nil
                    || (!controller.isRecording && !controller.canManageSessions))
            if let pending = controller.pendingAppleLanguage {
                Text("切換為\(pending == "en" ? "英文" : "中文")中 · 錄音持續保存")
                    .font(.caption).foregroundStyle(gold)
            } else {
                Text("錄音中可切換；請在語言改變前或停頓處按下。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recordingHeader: some View {
        VStack(spacing: 12) {
            TextField("課堂名稱", text: $controller.title)
                .font(.headline).multilineTextAlignment(.center)
                .onChange(of: controller.title) { value in
                    if controller.session != nil { controller.rename(value) }
                }
            HStack(spacing: 10) {
                if controller.isRecording { Circle().fill(red).frame(width: 10, height: 10) }
                Text(TranscriptExport.clock(controller.duration))
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityLabel("錄音時間 \(TranscriptExport.clock(controller.duration))")
            }
            if controller.usesAppleSpeech {
                appleLanguageControls.frame(maxWidth: 560)
            } else {
            Picker("辨識語言", selection: Binding(get: {
                RecognitionLanguage.isMixed(controller.language) ? "mixed" : controller.language
            }, set: { value in
                controller.setLanguage(value == "mixed" && controller.language == "en" ? "mixed-en" : value)
            })) {
                Text("自動").tag("auto")
                Text("中英夾雜").tag("mixed")
                Text("中文").tag("zh")
                Text("英文").tag("en")
            }.pickerStyle(.segmented).disabled(!controller.canManageSessions).frame(maxWidth: 560)
            if RecognitionLanguage.isMixed(controller.language) {
                Picker("混說主要語言", selection: Binding(get: {
                    RecognitionLanguage.primary(controller.language) ?? "zh"
                }, set: { controller.setLanguage($0 == "en" ? "mixed-en" : "mixed") })) {
                    Text("中文為主").tag("zh")
                    Text("英文為主").tag("en")
                }.pickerStyle(.segmented).disabled(!controller.canManageSessions).frame(maxWidth: 400)
                    .accessibilityIdentifier("mixedPrimaryLanguage")
            }
            if controller.usesSenseVoice {
                Text("SenseVoice 使用前後重疊音訊更新草稿，再按停頓或視窗上限定稿。低音量也送入模型；錄後可從匯出選單另存重新轉錄。重疊參數與接縫準確度仍需真機驗證。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
            Text(RecognitionLanguage.isMixed(controller.language) ? (controller.usesAppleSpeech ? "Apple 每次以一個主要語言辨識，不保證中英混說。單語課堂請選中文或英文。" : "依實際主要語言辨識；混說準確率仍需核對。停止後可切換。") : "指定主要語言有助辨識。Apple 引擎使用系統支援的語言資源。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            }
            HStack(spacing: 8) {
                if controller.isBusy || controller.isDecoding { ProgressView().controlSize(.small) }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = controller.progress { ProgressView(value: progress).frame(maxWidth: 560) }
            if controller.isRecording {
                ProgressView(value: Double(controller.level)).tint(red).frame(maxWidth: 300)
                    .accessibilityLabel("麥克風音量")
            }
        }
    }

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compactMode {
            HStack {
                Label("即時字幕", systemImage: "captions.bubble.fill").font(.caption.bold())
                Spacer()
                Text(controller.displayedDraft.isEmpty ? "已確認" : "辨識中 · 可修正").font(.caption)
            }.foregroundStyle(.white.opacity(0.7))
            }
            Text(controller.caption.isEmpty ? "等待語音…" : controller.caption)
                .font(.system(size: captionFontSize, weight: .medium)).lineLimit(compactMode ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
            if controller.translationEnabled && !controller.translationCaption.isEmpty {
                Text(controller.translationCaption).font(.system(size: translationFontSize)).lineLimit(compactMode ? nil : 4)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.45))
                if !compactMode && !controller.validTranslatedDraft.isEmpty {
                    Text("翻譯草稿 · 稍晚於原文更新").font(.caption2).foregroundStyle(.white.opacity(0.65))
                }
            }
        }.padding(16).background(Color(red: 0.13, green: 0.13, blue: 0.14))
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $controller.translationEnabled) {
                Label("即時翻譯字幕", systemImage: "captions.bubble.fill").font(.headline)
            }.tint(.green).accessibilityIdentifier("translationToggle")
            Text(controller.translationStatus).font(.caption).foregroundStyle(.secondary)
            if controller.translationEnabled {
                Text((controller.translationSource == "ja" ? "日文 → 繁體中文" : "英文 → 繁體中文") + " · 先顯示草稿，再保存確認段落；翻譯會比原文稍晚。")
                    .font(.caption).foregroundStyle(gold)
                Button("重試翻譯") { controller.restartTranslation() }.font(.caption)
            }
        }.padding(16).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
    }

    private func transcriptPane(translated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(translated ? "中文翻譯" : "即時逐字稿",
                      systemImage: translated ? "character.bubble" : "waveform")
                    .font(.headline).foregroundStyle(translated ? gold : ink)
                Spacer()
                Text(translated ? "繁體中文" : "原文").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if controller.session?.lines.isEmpty != false && controller.displayedDraft.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: translated ? "character.bubble" : "waveform")
                                    .font(.system(size: 30)).foregroundStyle(gold.opacity(0.7))
                                Text(translated ? "讓理解跟上對話" : "把注意力留給課堂").font(.title3.bold())
                                Text(translated ? "英語會逐段翻成中文，中文內容保留原文。首次使用請允許下載翻譯語言。" : "按下開始錄音，文字會在這裡逐步出現。灰色草稿可能修正，確認後自動保存。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical, 28)
                        }
                        ForEach(controller.session?.lines ?? []) { line in
                            if let text = paneText(line, translated: translated),
                               controller.search.isEmpty || text.localizedCaseInsensitiveContains(controller.search) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(TranscriptExport.clock(line.start) + " · " + (controller.session?.speakerLabel(line) ?? ""))
                                        .font(.caption.monospacedDigit()).foregroundStyle(gold)
                                    Text(text).font(.system(size: transcriptFontSize)).lineSpacing(4).textSelection(.enabled)
                                    if !translated {
                                        Button("聽這段原音／核對切點") { reviewedLine = line }.font(.caption).disabled(!controller.canManageSessions)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if !translated {
                                        Button("編輯文字") { editedLine = line }.disabled(!controller.canManageSessions)
                                        if line.userEdited == true { Button("解除手動修改鎖定") { controller.unlockLine(line.id) }.disabled(!controller.canManageSessions) }
                                        if let names = controller.session?.speakerNames {
                                            ForEach(names.keys.sorted(), id: \.self) { id in
                                                Button("設為 " + (names[id] ?? id)) { controller.assignSpeaker(line.id, speaker: id) }.disabled(!controller.canManageSessions)
                                            }
                                            Button("講者未確認") { controller.assignSpeaker(line.id, speaker: "unconfirmed") }.disabled(!controller.canManageSessions)
                                        }
                                    }
                                    Button("複製") { UIPasteboard.general.string = text }
                                }
                            }
                        }
                        let draft = translated ? controller.validTranslatedDraft : controller.displayedDraft
                        if controller.search.isEmpty && !draft.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("草稿 · 可能更新").font(.caption).foregroundStyle(gold)
                                Text(draft).font(.system(size: transcriptFontSize)).lineSpacing(4)
                            }.foregroundStyle(.secondary)
                        }
                        if !translated, let marks = controller.session?.bookmarks, !marks.isEmpty {
                            Divider()
                            ForEach(marks) { mark in
                                Label("\(TranscriptExport.clock(mark.seconds))  \(mark.note)", systemImage: "bookmark.fill")
                                    .font(.caption).foregroundStyle(gold)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: controller.session?.lines.count) { _ in scrollLatest(proxy) }
                .onChange(of: controller.session?.lines.last?.text) { _ in if !translated { scrollLatest(proxy) } }
                .onChange(of: controller.session?.translations?.count) { _ in scrollLatest(proxy) }
                .onChange(of: controller.displayedDraft) { _ in if !translated { scrollLatest(proxy) } }
                .onChange(of: controller.validTranslatedDraft) { _ in if translated { scrollLatest(proxy) } }
            }
        }.padding(20).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
    }
    private func paneText(_ line: TranscriptLine, translated: Bool) -> String? {
        translated ? controller.session?.translation(for: line)?.text : line.text
    }
    private func scrollLatest(_ proxy: ScrollViewProxy) {
        if followLatest && controller.search.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !compactMode {
            HStack(spacing: 12) {
                Button {
                    if let url = controller.exportNotes(translation: true) { sharedFile = SharedFile(url: url) }
                } label: { Label("分享翻譯", systemImage: "square.and.arrow.up") }
                    .disabled(controller.session?.translations?.isEmpty != false)
                Spacer()
                Button {
                    showMinutes = true
                } label: { Label("會議紀錄", systemImage: "doc.text").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.session?.lines.isEmpty != false)
            }.font(.callout)
            }
            HStack(spacing: 12) {
                Button {
                    Task {
                        if controller.isRecording { await controller.pause() }
                        else if controller.session?.hasPendingAudio == true { await controller.recover() }
                        else { await controller.start() }
                    }
                } label: {
                    Label(recordLabel, systemImage: controller.isRecording ? "stop.fill" : "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(red).clipShape(Capsule())
                .disabled(controller.isBusy || controller.isSummarizing || (!controller.isRecording && !controller.canStart && controller.session?.hasPendingAudio != true))
                Button { showBookmark = true } label: {
                    Image(systemName: "bookmark").font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.bordered).clipShape(Circle()).disabled(controller.session == nil)
                    .accessibilityLabel("加入重點標記")
            }
            if controller.isSummarizing {
                Text(controller.summaryStatus).font(.caption).foregroundStyle(gold)
            } else if let saved = controller.lastSaved {
                Text("已儲存到本機 · \(saved.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 1200).frame(maxWidth: .infinity).background(paper)
    }
    private var recordLabel: String {
        if controller.isRecording { return "停止並儲存" }
        if controller.session?.hasPendingAudio == true { return "補辨識" }
        return controller.session == nil ? "開始錄音" : "繼續錄音"
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                // SECTION 1: 辨識核心 (置頂)
                Section(L10n.tr("1. 辨識核心", "1. Recognition Engine")) {
                    Picker(L10n.tr("辨識引擎", "Speech Engine"), selection: Binding(get: { controller.recognitionEngine }, set: { value in
                        controller.setRecognitionEngine(value)
                        if value == "apple" && controller.language == "auto" { controller.setLanguage("zh") }
                        if value == "sensevoice" { controller.setLanguage("auto") }
                    })) {
                        Text(L10n.tr("Apple 即時語音 · iPadOS 26", "Apple Speech · Live")).tag("apple")
                        Text(L10n.tr("WhisperKit · Turbo 等模型", "WhisperKit · Models")).tag("whisper")
                        Text(L10n.tr("SenseVoice Core ML · 中英混說實驗版", "SenseVoice Core ML · Bilingual")).tag("sensevoice")
                    }.disabled(!controller.canManageSessions)

                    if controller.usesWhisper {
                        Picker(L10n.tr("語音模型", "Whisper Model"), selection: $controller.model) {
                            ForEach(SpeechModel.allCases) { Text($0.title).tag($0.rawValue) }
                        }.disabled(controller.settingsLocked)
                    }

                    HStack {
                        Text(L10n.tr("核心狀態", "Engine Status"))
                        Spacer()
                        Text(controller.loadedModel != nil ? L10n.tr("已載入就緒", "Loaded & Ready") : L10n.tr("尚未載入", "Not Loaded"))
                            .font(.caption.bold())
                            .foregroundStyle(controller.loadedModel != nil ? Color.green : Color.secondary)
                    }

                    Text(L10n.tr("純中文／英文推薦 Apple；多語言混說推薦 SenseVoice；離線錄後長文高精度推薦 WhisperKit。", "Apple Speech recommended for pure Zh/En; SenseVoice for bilingual speech; WhisperKit for high accuracy."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 2: 即時翻譯
                Section(L10n.tr("2. 即時翻譯", "2. Live Translation")) {
                    Toggle(L10n.tr("即時翻譯字幕", "Live Translation"), isOn: $controller.translationEnabled)
                        .tint(.green)

                    Picker(L10n.tr("更新頻率預設檔", "Update Frequency"), selection: $controller.translationSpeedPreset) {
                        ForEach(TranslationSpeedPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if controller.translationSpeedPreset == .custom {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("自訂更新間隔：\(String(format: "%.2f", controller.translationCustomInterval)) 秒", "Custom interval: \(String(format: "%.2f", controller.translationCustomInterval))s"))
                                .font(.caption)
                            Slider(value: $controller.translationCustomInterval, in: 0.20...2.00, step: 0.05)
                        }
                    }

                    Toggle(L10n.tr("低延遲即時模式", "Low Latency Live Mode"), isOn: $controller.isLowLatencyTranslation)

                    Picker(L10n.tr("翻譯服務提供者", "Translation Provider"), selection: $controller.translationProvider) {
                        Text(L10n.tr("Apple 裝置端翻譯（內建）", "Apple On-Device (Built-in)")).tag("apple")
                        Text(L10n.tr("Google 雲端翻譯（未啟用）", "Google Cloud (Disabled)")).tag("google")
                        Text(L10n.tr("Microsoft 翻譯（未啟用）", "Microsoft Azure (Disabled)")).tag("microsoft")
                    }

                    if controller.translationEnabled {
                        Text(controller.translationStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("重試翻譯", "Retry Translation")) {
                            controller.restartTranslation()
                        }.font(.caption)
                    }

                    Text(L10n.tr("雙軌機制：LIVE 優先更新最新語音，BACKLOG 按順序補齊已定稿段落。切換辨識引擎不影響翻譯進行。", "Dual-lane architecture: LIVE prioritizes newest draft speech, BACKLOG completes confirmed lines. Engine switches do not interrupt translation."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 3: 語言設定
                Section(L10n.tr("3. 語言設定", "3. Language Settings")) {
                    Picker(L10n.tr("App 介面語言", "App UI Language"), selection: Binding(get: { L10n.shared.appLanguage }, set: { L10n.shared.appLanguage = $0 })) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }

                    Picker(L10n.tr("辨識語言", "Recognition Language"), selection: Binding(get: {
                        RecognitionLanguage.isMixed(controller.language) ? "mixed" : controller.language
                    }, set: { value in
                        controller.setLanguage(value == "mixed" && controller.language == "en" ? "mixed-en" : value)
                    })) {
                        Text(L10n.tr("自動", "Auto")).tag("auto")
                        Text(L10n.tr("中英夾雜", "Mixed")).tag("mixed")
                        Text(L10n.tr("中文", "Chinese")).tag("zh")
                        Text(L10n.tr("英文", "English")).tag("en")
                    }.disabled(!controller.canManageSessions)

                    Picker(L10n.tr("翻譯來源語言", "Translation Source"), selection: Binding(get: { controller.translationSource }, set: { controller.setTranslationSource($0) })) {
                        Text(L10n.tr("英文 → 繁中", "English → Chinese")).tag("en")
                        Text(L10n.tr("日文 → 繁中", "Japanese → Chinese")).tag("ja")
                    }

                    let cap = EngineCapability.isSupported(engine: controller.recognitionEngine, language: controller.language)
                    Text(cap.detail)
                        .font(.caption).foregroundStyle(cap.supported ? Color.secondary : Color.orange)
                }

                // SECTION 4: PiP 字幕
                Section(L10n.tr("4. PiP 字幕與精簡視窗", "4. Caption PiP & Compact Window")) {
                    Picker(L10n.tr("字幕顯示模式", "Display Mode"), selection: $pip.displayMode) {
                        ForEach(PiPDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Button(L10n.tr("開啟子母畫面字幕條 (1200×240)", "Start PiP Subtitle Bar (1200×240)")) {
                        showSettings = false; pipPreview = true; controller.pipEnabled = true
                    }
                    Button(L10n.tr("精簡小視窗字幕", "Compact Window Subtitles")) {
                        showSettings = false; pip.detach(); pipPreview = false; controller.pipEnabled = false; compactMode = true
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("原文字幕大小：\(Int(captionFontSize))", "Original Font Size: \(Int(captionFontSize))"))
                        Slider(value: $captionFontSize, in: 14...48, step: 1)
                            .accessibilityLabel("原文字幕大小")
                            .accessibilityIdentifier("原文字幕大小")
                        Text(L10n.tr("翻譯字幕大小：\(Int(translationFontSize))", "Translation Font Size: \(Int(translationFontSize))"))
                        Slider(value: $translationFontSize, in: 14...48, step: 1)
                            .accessibilityLabel("翻譯字幕大小")
                            .accessibilityIdentifier("翻譯字幕大小")
                        Text(L10n.tr("逐字稿字級：\(Int(transcriptFontSize))", "Transcript Font Size: \(Int(transcriptFontSize))"))
                        Slider(value: $transcriptFontSize, in: 14...36, step: 1)
                            .accessibilityLabel("逐字稿大小")
                            .accessibilityIdentifier("逐字稿大小")
                    }
                }

                // SECTION 5: 模型與資源管理
                Section(L10n.tr("5. 模型與資源管理", "5. Model & Resource Management")) {
                    HStack {
                        Text(L10n.tr("目前進度", "Current Progress"))
                        Spacer()
                        Text(controller.resourceState.description)
                            .font(.caption)
                            .foregroundStyle(controller.resourceState.isReady ? Color.green : Color.secondary)
                    }
                    if let p = controller.resourceState.progressValue {
                        ProgressView(value: p)
                    }
                    Button {
                        Task { await controller.prepareModel() }
                    } label: {
                        Label(controller.loadedModel != nil ? L10n.tr("模型已就緒", "Model Ready") : L10n.tr("下載 / 載入模型", "Download / Load Model"), systemImage: "arrow.down.circle")
                    }
                    .accessibilityLabel("載入模型")
                    .accessibilityIdentifier("載入模型")
                    .disabled(!controller.canManageSessions)

                    Text(L10n.tr("模型統一儲存於 Application Support / SpeechModels，支援完全離線辨識。進度條依真實傳輸位元組計算，絕無假百分比。", "Models stored in Application Support / SpeechModels for offline use. Real byte-level download progress."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 6: 錄音品質與儲存
                Section(L10n.tr("6. 錄音品質與儲存", "6. Audio Quality & Storage")) {
                    Picker(L10n.tr("儲存品質", "Audio Quality"), selection: Binding(get: { controller.recordingQuality }, set: { controller.setRecordingQuality($0) })) {
                        ForEach(RecordingQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("recordingQuality")
                    .disabled(!controller.canManageSessions)

                    Text(L10n.tr("只影響接下來的新錄音片段。辨識使用未經 AAC 壓縮的 16 kHz 單聲道音訊；停止並補完辨識後才壓縮保存。", "Affects new segments. Raw 16 kHz PCM used during capture; compressed upon completion."))
                        .font(.caption)
                }

                // SECTION 7: 專有名詞提示
                Section(L10n.tr("7. 專有名詞自訂詞庫", "7. Vocabulary & Prompt")) {
                    TextField(L10n.tr("例如：CRISPR、Cas9、gene editing", "e.g. CRISPR, Cas9, gene editing"), text: $controller.vocabulary, axis: .vertical)
                        .lineLimit(3...5).disabled(controller.settingsLocked || !controller.usesWhisper)
                        .onChange(of: controller.vocabulary) { value in
                            if value.count > 500 { controller.vocabulary = String(value.prefix(500)) }
                        }
                    Text(L10n.tr("自訂專有名詞提示 WhisperKit 解碼偏好，最多 500 字元。", "Custom prompt words hinting WhisperKit decoding, max 500 characters."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 8: 智慧筆記
                Section(L10n.tr("8. 智慧筆記與 AI 整理", "8. Smart Notes & Summary")) {
                    Text(L10n.tr("AI 整理使用 iPadOS 26 的 Apple Intelligence。若未啟用將產生具時間戳之原文整理。", "AI notes use on-device Apple Intelligence or structured timeline outline."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("SenseVoice 重新轉錄（另存新課堂）", "Retranscribe with SenseVoice (Save As New)")) {
                        showSettings = false
                        Task { await controller.retranscribeRecording() }
                    }.disabled(!controller.canManageSessions || controller.session?.parts.contains { $0.sampleCount > 0 } != true)
                }

                // SECTION 9: 側載簽名維護
                Section(L10n.tr("9. 側載簽名維護", "9. SideStore Self-Refresh")) {
                    SigningExpirationSection()
                }

                // SECTION 10: 關於與版本
                Section(L10n.tr("10. 關於與版本更新", "10. About & Version")) {
                    Text(L10n.tr("目前版本：", "Current Version: ") + updates.current)
                    Toggle(L10n.tr("開啟 App 時檢查更新", "Check updates on launch"), isOn: $automaticallyCheckUpdates)
                    Button(L10n.tr("檢查更新", "Check for Updates")) { Task { await updates.check() } }
                        .accessibilityLabel("檢查更新")
                        .accessibilityIdentifier("檢查更新")
                        .disabled(updates.checking)
                    if let update = updates.available {
                        Text(update.version + "：" + update.notes)
                        Button(L10n.tr("透過 SideStore 更新", "Update via SideStore")) { updates.openSideStore(source: false) }
                            .disabled(!controller.canManageSessions || pip.active)
                    }
                    Button(L10n.tr("加入 SideStore 更新來源", "Add SideStore Source")) { updates.openSideStore(source: true) }
                        .disabled(!controller.canManageSessions || pip.active)
                    Text(updates.status).font(.caption)
                    Text(L10n.tr("由 SideStore 下載、簽署與安裝；錄音／處理期間不啟動更新。", "Downloaded, signed, and installed via SideStore."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.tr("錄音設定", "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done")) { showSettings = false }
                        .accessibilityLabel("完成")
                        .accessibilityIdentifier("完成")
                }
            }
        }
    }

    private var minutesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("把對話整理成可回顧的記錄", systemImage: "doc.text")
                        .font(.title3.bold())
                    Text("停止錄音並完成補辨識後，可用裝置端 AI 整理重點、明確決議與待辦。結果需要對照原文確認。")
                        .foregroundStyle(.secondary)
                    Text("整理偏好（在這台裝置保存，最多 800 字）").font(.headline)
                    TextEditor(text: $controller.notesPrompt).frame(minHeight: 100)
                        .disabled(controller.isSummarizing)
                        .onChange(of: controller.notesPrompt) { _ in controller.saveNotesPrompt() }
                    Button("恢復預設提示詞") {
                        controller.notesPrompt = "以繁體中文整理重點、決議、待辦；保留英文術語和來源時間戳。"; controller.saveNotesPrompt()
                    }.disabled(controller.isSummarizing)
                    Button(controller.session?.minutes == nil ? "產生會議紀錄" : "重新整理") {
                        Task { await controller.generateMinutes() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!controller.canManageSessions || controller.session?.hasPendingAudio == true)
                    Button("使用原文整理（不需要 Apple Intelligence）") { controller.makeOutline() }
                        .disabled(!controller.canManageSessions)
                    if controller.isSummarizing { ProgressView(controller.summaryStatus) }
                    else if !controller.summaryStatus.isEmpty { Text(controller.summaryStatus).font(.caption) }
                    if let current = controller.session, let notes = current.minutes {
                        if let prompt = current.minutesPrompt { Text("本次整理偏好：" + prompt).font(.caption).foregroundStyle(.secondary) }
                        if !current.minutesAreCurrent {
                            Label("逐字稿已更新，請重新整理", systemImage: "arrow.clockwise").foregroundStyle(.orange)
                        }
                        Divider()
                        ForEach(Array(notes.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("#") {
                                Text(line.drop(while: { $0 == "#" || $0 == " " })).font(.headline)
                            } else if !line.isEmpty {
                                Text(line).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity, alignment: .leading)
            }.background(paper).navigationTitle("會議紀錄")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { showMinutes = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: (controller.session?.minutesAreCurrent == false ? "注意：逐字稿已有更新，這是先前整理的版本。\n\n" : "") + (controller.session?.minutes ?? "")) { Label("分享", systemImage: "square.and.arrow.up") }
                            .disabled(controller.session?.minutes == nil)
                    }
                }
        }.tint(gold)
    }

    private var filteredHistory: [LectureSession] {
        if historySearch.isEmpty { return controller.history }
        return controller.history.filter { session in
            session.title.localizedCaseInsensitiveContains(historySearch) ||
            session.lines.contains { $0.text.localizedCaseInsensitiveContains(historySearch) }
        }
    }

    private var groupedHistory: [(title: String, sessions: [LectureSession])] {
        let calendar = Calendar.current
        var today: [LectureSession] = []
        var yesterday: [LectureSession] = []
        var earlier: [LectureSession] = []

        for session in filteredHistory {
            if calendar.isDateInToday(session.createdAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.createdAt) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        var result: [(title: String, sessions: [LectureSession])] = []
        if !today.isEmpty {
            result.append((L10n.tr("今天", "Today"), today))
        }
        if !yesterday.isEmpty {
            result.append((L10n.tr("昨天", "Yesterday"), yesterday))
        }
        if !earlier.isEmpty {
            result.append((L10n.tr("更早之前", "Earlier"), earlier))
        }
        return result
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                if filteredHistory.isEmpty {
                    Text(controller.history.isEmpty ? L10n.tr("還沒有已儲存的課堂", "No saved lectures yet") : L10n.tr("沒有符合搜尋的課堂", "No matching lectures found"))
                        .accessibilityIdentifier("還沒有已儲存的課堂")
                        .foregroundStyle(.secondary)
                }
                ForEach(groupedHistory, id: \.title) { group in
                    Section(header: Text(group.title).font(.subheadline.bold()).foregroundStyle(gold)) {
                        ForEach(group.sessions) { session in
                            NavigationLink {
                                LectureDetailView(controller: controller, session: session)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(session.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 8) {
                                        Text(session.createdAt.formatted(date: .numeric, time: .shortened))
                                        Text("·")
                                        Text(TranscriptExport.clock(session.duration))
                                        Text("·")
                                        Text(L10n.tr("音訊 ", "Audio ") + controller.audioSize(session))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    HStack(spacing: 6) {
                                        let engineName = session.recognitionEngine ?? "whisper"
                                        Text(engineName == "apple" ? "Apple Speech" : (engineName == "sensevoice" ? "SenseVoice" : "Whisper"))
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12))
                                            .foregroundStyle(Color.blue)
                                            .clipShape(Capsule())

                                        if !session.transcriptVersions.isEmpty {
                                            Text("\(session.transcriptVersions.count) " + L10n.tr("版本", "versions"))
                                                .font(.system(size: 10))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(gold.opacity(0.15))
                                                .foregroundStyle(gold)
                                                .clipShape(Capsule())
                                        }
                                    }

                                    if let firstLine = session.lines.first?.text, !firstLine.isEmpty {
                                        Text(firstLine)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    if session.hasPendingAudio {
                                        Label(L10n.tr("有錄音等待補辨識", "Audio pending transcription"), systemImage: "arrow.clockwise")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(L10n.tr("刪除", "Delete"), role: .destructive) {
                                    pendingDeletion = session
                                }
                                Button(L10n.tr("重命名", "Rename")) {
                                    renamingSession = session
                                    renameTitle = session.title
                                    showRenameAlert = true
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    controller.open(session)
                                    showHistory = false
                                } label: {
                                    Label(L10n.tr("載入繼續錄音", "Resume in Main"), systemImage: "mic")
                                }
                                Button {
                                    renamingSession = session
                                    renameTitle = session.title
                                    showRenameAlert = true
                                } label: {
                                    Label(L10n.tr("重新命名", "Rename"), systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    pendingDeletion = session
                                } label: {
                                    Label(L10n.tr("刪除課堂", "Delete"), systemImage: "trash")
                                }
                            }
                            .disabled(!controller.canManageSessions)
                        }
                    }
                }
            }
            .searchable(text: $historySearch, prompt: L10n.tr("搜尋課堂標題或逐字稿", "Search title or transcript"))
            .navigationTitle(L10n.tr("本機課堂", "Library"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        importAfterHistory = true
                        showHistory = false
                    } label: {
                        Label(L10n.tr("匯入音訊", "Import Audio"), systemImage: "square.and.arrow.down")
                            .font(.body.bold())
                    }
                    .accessibilityIdentifier("匯入音訊")
                    .accessibilityLabel(L10n.tr("匯入音訊", "Import Audio"))
                    .disabled(!controller.canManageSessions)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done")) { showHistory = false }
                        .accessibilityLabel("完成")
                        .accessibilityIdentifier("完成")
                }
            }
            .alert("重新命名課堂", isPresented: $showRenameAlert) {
                TextField("課堂名稱", text: $renameTitle)
                Button("儲存") {
                    if let s = renamingSession {
                        controller.renameLecture(s.id, title: renameTitle)
                    }
                    renamingSession = nil
                }
                Button("取消", role: .cancel) {
                    renamingSession = nil
                }
            }
            .confirmationDialog("刪除這堂課？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("刪除錄音與所有逐字稿", role: .destructive) {
                    if let item = pendingDeletion { controller.deleteLecture(item.id) }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { Text("將刪除「\(pendingDeletion?.title ?? "")」的錄音、所有版本逐字稿、標記與本機匯出檔，無法復原。已分享出去的檔案不受影響。") }
        }
    }
}

struct LineEditor: View {
    let line: TranscriptLine
    let save: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding().navigationTitle("編輯逐字稿")
                .onAppear { text = line.text }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("儲存") { save(text); dismiss() } }
                }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
