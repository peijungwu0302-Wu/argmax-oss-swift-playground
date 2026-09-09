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
    @State private var captionMode = true
    @State private var compactMode = false
    private let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
    private let ink = Color(red: 0.20, green: 0.19, blue: 0.16)
    private let gold = Color(red: 0.59, green: 0.40, blue: 0.08)
    private let red = Color(red: 0.69, green: 0.18, blue: 0.14)

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if compactMode {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !compactMode && captionMode && (controller.isRecording || !controller.caption.isEmpty) { captionPanel }
                    bottomBar
                }
            }
            .navigationTitle(compactMode ? "字幕" : "錄音")
            .navigationBarTitleDisplayMode(.inline)
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
                        Button("錄音檔案：播放與分享") { showAudio = true }
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
                if let lecture = controller.session { NavigationStack { AudioLibraryView(controller: controller, lecture: lecture) } }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio, .data]) { result in
                switch result {
                case .success(let url): Task { await controller.importAudio(url) }
                case .failure(let error): controller.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(isPresented: $showMinutes) { minutesSheet }
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
    }

    private var compactWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Circle().fill(controller.isRecording ? red : .gray).frame(width: 9, height: 9)
                    Text(TranscriptExport.clock(controller.duration)).font(.title2.monospacedDigit())
                    Spacer()
                }
                Text(controller.title.isEmpty ? "課堂字幕" : controller.title).font(.headline).lineLimit(1)
                if controller.usesAppleSpeech { appleLanguageControls }
                Toggle("中文翻譯", isOn: $controller.translationEnabled).tint(.green)
                captionPanel.clipShape(RoundedRectangle(cornerRadius: 12))
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                if controller.translationEnabled {
                    Text(controller.translationStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("iPad 可在系統支援的視窗模式下與 Goodnotes 並排或使用 Slide Over。" + controller.backgroundDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("compactCaptionWorkspace")
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
                Text("SenseVoice 約每秒重辨識草稿；依安靜／背景音量調整停頓切點，最長 12 秒；音樂中優先找較低音量切點。自動模式可混說；主要語言是模型提示，不會關閉另一種語言。實際速度與準確度需實測。")
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
            HStack {
                Label("即時字幕", systemImage: "captions.bubble.fill").font(.caption.bold())
                Spacer()
                Text(controller.displayedDraft.isEmpty ? "已確認" : "辨識中 · 可修正").font(.caption)
            }.foregroundStyle(.white.opacity(0.7))
            Text(controller.caption.isEmpty ? "等待語音…" : controller.caption)
                .font(.system(size: 25, weight: .medium)).lineLimit(2).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
            if controller.translationEnabled && !controller.translationCaption.isEmpty {
                Text(controller.translationCaption).font(.title3).lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.45))
                if !controller.validTranslatedDraft.isEmpty {
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
                Text("翻成繁體中文 · 先顯示草稿，再保存確認段落；翻譯會比原文稍晚。")
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
                                    Text(TranscriptExport.clock(line.start))
                                        .font(.caption.monospacedDigit()).foregroundStyle(gold)
                                    Text(text).lineSpacing(4).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if !translated {
                                        Button("編輯文字") { editedLine = line }.disabled(controller.isSummarizing)
                                    }
                                    Button("複製") { UIPasteboard.general.string = text }
                                }
                            }
                        }
                        let draft = translated ? controller.validTranslatedDraft : controller.displayedDraft
                        if controller.search.isEmpty && !draft.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("草稿 · 可能更新").font(.caption).foregroundStyle(gold)
                                Text(draft).lineSpacing(4)
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
                Section("語音辨識") {
                    Picker("辨識引擎", selection: Binding(get: { controller.recognitionEngine }, set: { value in
                        controller.setRecognitionEngine(value)
                        if value == "apple" && controller.language == "auto" { controller.setLanguage("zh") }
                        if value == "sensevoice" { controller.setLanguage("auto") }
                    })) {
                        Text("Apple 即時語音 · iPadOS 26").tag("apple")
                        Text("WhisperKit · Turbo 等模型").tag("whisper")
                        Text("SenseVoice Core ML · 中英混說實驗版").tag("sensevoice")
                    }.disabled(!controller.canManageSessions)
                    if controller.usesWhisper {
                    Picker("語音模型", selection: $controller.model) {
                        ForEach(SpeechModel.allCases) { Text($0.title).tag($0.rawValue) }
                    }.disabled(controller.settingsLocked)
                    }
                    Button { Task { await controller.prepareModel() } } label: {
                        Label(controller.loadedModel != nil ? "模型已就緒" : "載入模型", systemImage: "arrow.down.circle")
                    }.disabled(!controller.canManageSessions)
                    Text("純中文／英文可用 Apple；中英混說可試 SenseVoice Core ML INT8（首次下載約 240 MB）。開始錄音會自動載入，之後可離線辨識。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("錄音儲存品質") {
                    Picker("儲存品質", selection: Binding(get: { controller.recordingQuality }, set: { controller.setRecordingQuality($0) })) {
                        ForEach(RecordingQuality.allCases) { Text($0.title).tag($0) }
                    }.disabled(!controller.canManageSessions).accessibilityIdentifier("recordingQuality")
                    Text("只影響接下來的新錄音片段。辨識使用未經 AAC 壓縮的 16 kHz 單聲道音訊；停止並補完辨識後才壓縮保存。")
                        .font(.caption)
                    Text("錄音中暫存約 115 MB／小時，壓縮時還需要成品空間。原本的錄音不會自動轉檔；中斷或壓縮失敗時保留原始音訊。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("課堂專有名詞") {
                    TextField("例如：CRISPR、Cas9、gene editing", text: $controller.vocabulary, axis: .vertical)
                        .lineLimit(3...5).disabled(controller.settingsLocked || !controller.usesWhisper)
                        .onChange(of: controller.vocabulary) { value in
                            if value.count > 500 { controller.vocabulary = String(value.prefix(500)) }
                        }
                    Text("目前專有名詞提示只用於 WhisperKit；不能保證人名與術語正確。").font(.caption)
                }
                Section("辨識狀態") {
                    if let seconds = controller.lastDecodeSeconds {
                        Text(String(format: "本輪辨識 %.1f 秒", seconds))
                        Text(String(format: "草稿音訊落後 %.1f 秒", controller.draftBehindSeconds))
                    }
                    Text("尚未定稿 \(Int(controller.pendingSeconds)) 秒")
                    Text(controller.backgroundDescription)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("翻譯來源語言") {
                    Picker("翻成繁體中文", selection: Binding(get: { controller.translationSource }, set: { controller.setTranslationSource($0) })) {
                        Text("英文 → 中文（中英混說保留中文）").tag("en")
                        Text("日文 → 中文").tag("ja")
                    }
                    Text("來源切換後會重新翻譯已有段落；語音辨識引擎不變。日文可用 SenseVoice 自動辨識。").font(.caption)
                }
                Section("會議整理") {
                    Text("AI 整理使用 iPadOS 26 的 Apple Intelligence。請在系統設定啟用並完成模型下載；若不可用，會產生保留時間戳的原文整理。")
                        .font(.callout)
                }
            }.navigationTitle("錄音設定")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
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

    private var historySheet: some View {
        NavigationStack {
            List {
                if controller.history.isEmpty { Text("還沒有已儲存的課堂").foregroundStyle(.secondary) }
                ForEach(controller.history) { session in
                    HStack {
                        Button {
                            controller.open(session); showHistory = false
                        } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.title).font(.headline)
                            Text("\(session.createdAt.formatted()) · \(TranscriptExport.clock(session.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("音訊 " + controller.audioSize(session)).font(.caption).foregroundStyle(.secondary)
                            if session.hasPendingAudio { Label("有錄音等待補辨識", systemImage: "arrow.clockwise").font(.caption) }
                        }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        Spacer()
                        NavigationLink {
                            AudioLibraryView(controller: controller, lecture: session)
                        } label: { Image(systemName: "waveform").accessibilityLabel("錄音檔案") }.fixedSize()
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("刪除 \(session.title)")
                    }
                    .swipeActions(allowsFullSwipe: false) { Button("刪除", role: .destructive) { pendingDeletion = session } }
                    .disabled(!controller.canManageSessions)
                }
            }.navigationTitle("本機課堂")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("匯入音訊") { importAfterHistory = true; showHistory = false }.disabled(!controller.canManageSessions)
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showHistory = false } }
                }
                .confirmationDialog("刪除這堂課？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                    Button("刪除錄音與逐字稿", role: .destructive) {
                        if let item = pendingDeletion { controller.deleteLecture(item.id) }
                        pendingDeletion = nil
                    }
                    Button("取消", role: .cancel) { pendingDeletion = nil }
                } message: { Text("將刪除「\(pendingDeletion?.title ?? "")」的錄音、逐字稿、標記與本機匯出檔，無法復原。已分享出去的檔案不受影響。") }
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
