import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct ContentView: View {
    @ObservedObject var controller: LectureController
    @EnvironmentObject private var navigation: AppNavigationState
    @EnvironmentObject private var pipSettings: PiPPresentationSettings
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var courseVocabulary = CourseVocabulary.shared
    @ObservedObject private var deviceAudioCapture = DeviceAudioCaptureManager.shared
    @State private var showHistory = false
    @State private var showImport = false
    @State private var importAfterHistory = false
    @State private var showAudio = false
    @State private var showBookmark = false
    @State private var showSettings = false
    @State private var showCourseVocabulary = false
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
    private var isFullTranscript: Bool {
        if case .fullTranscript = navigation.route { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if case .fullTranscript(let id) = navigation.route {
                    FullTranscriptView(controller: controller, lectureID: id)
                } else {
                ScrollView {
                    VStack(spacing: 20) {
                        recordingHeader
                        translationCard
                        HStack {
                            Image(systemName: "magnifyingglass")
                            TextField(L10n.tr("搜尋逐字稿", "Search transcript"), text: $controller.search)
                            Toggle(L10n.tr("跟隨最新", "Follow latest"), isOn: $followLatest).font(.caption).fixedSize()
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
                    if !isFullTranscript && captionMode && (controller.isRecording || !controller.caption.isEmpty) { captionPanel }
                    if !isFullTranscript { bottomBar }
                }
            }
            .navigationTitle(L10n.tr("錄音", "Recording"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isFullTranscript ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { controller.reloadHistory(); showHistory = true } label: {
                        Label(L10n.tr("歷史紀錄", "History"), systemImage: "books.vertical")
                    }.disabled(!controller.canManageSessions)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        if let id = controller.session?.id { navigation.showFullTranscript(for: id) }
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .accessibilityLabel(L10n.tr("完整逐字稿", "Full Transcript"))
                    .disabled(controller.session == nil)
                    Button {
                        controller.pipEnabled = true
                        pip.setSamplePreview(false)
                        pip.start(recording: controller.isRecording)
                    } label: {
                        Image(systemName: pip.active ? "pip.fill" : "pip.enter")
                    }
                    .accessibilityLabel(L10n.tr("開啟子母字幕", "Open PiP Captions"))
                    .accessibilityIdentifier("openPiPCaptions")
                    Button { captionMode.toggle() } label: {
                        Image(systemName: captionMode ? "captions.bubble.fill" : "captions.bubble")
                    }.accessibilityLabel(L10n.tr("字幕模式", "Caption mode"))
                    Button { controller.newLecture() } label: { Label(L10n.tr("新課堂", "New Lecture"), systemImage: "square.and.pencil") }
                        .disabled(!controller.canManageSessions)
                    Button { showSettings = true } label: { Label(L10n.tr("錄音設定", "Settings"), systemImage: "slider.horizontal.3") }
                    Menu {
                        Button(L10n.tr("講者分析與命名（beta）", "Speaker Diarization (Beta)")) { showSpeakers = true }
                        if controller.session?.previousLines != nil { Button(L10n.tr("復原最近一次稿件替換", "Undo Last Revision")) { controller.undoReview() } }
                        Button(L10n.tr("錄音檔案：播放與分享", "Audio Files: Play & Share")) { showAudio = true }
                        Button(L10n.tr("SenseVoice 錄後重新轉錄（另存新課堂）", "SenseVoice Retranscribe (Save as New)")) {
                            Task { await controller.retranscribeRecording() }
                        }.disabled(controller.session?.parts.contains { $0.sampleCount > 0 } != true)
                        ForEach(TranscriptFormat.allCases) { format in
                            Button(L10n.tr("匯出 \(format.rawValue)", "Export \(format.rawValue)")) {
                                if let url = controller.export(format) { sharedFile = SharedFile(url: url) }
                            }
                        }
                        if controller.session?.minutes != nil {
                            Button(L10n.tr("查看會議紀錄", "View Meeting Notes")) { showMinutes = true }
                        }
                    } label: { Label(L10n.tr("匯出", "Export"), systemImage: "square.and.arrow.up") }
                    .disabled(controller.session == nil || !controller.canManageSessions)
                }
            }
            .tint(gold)
            .background(
                CaptionPiPPreview(
                    pip: pip,
                    original: controller.caption,
                    translated: controller.translationEnabled ? controller.translationCaption : "",
                    sourceSize: captionFontSize,
                    translationSize: translationFontSize
                )
                .frame(width: 2, height: 2)
                .opacity(0.01)
            )
            .modifier(LiveTranslationModifier(controller: controller))
            .sheet(isPresented: $showHistory, onDismiss: { if importAfterHistory { importAfterHistory = false; showImport = true } }) { historySheet }
            .sheet(isPresented: $showAudio) {
                if let lecture = controller.session { NavigationStack { LectureDetailView(controller: controller, session: lecture).toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("完成", "Done")) { showAudio = false } } } } }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio, .data]) { result in
                switch result {
                case .success(let url): Task { await controller.importAudio(url) }
                case .failure(let error): controller.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(isPresented: $showCourseVocabulary) { CourseVocabularySheet() }
            .sheet(isPresented: $showMinutes) { minutesSheet }
            .sheet(isPresented: $showSpeakers) { SpeakerSettingsView(controller: controller) }
            .sheet(item: $reviewedLine) { line in
                if let id = controller.session?.id { TranscriptReviewView(controller: controller, line: line, sessionID: id) }
            }
            .sheet(item: $sharedFile) { file in ShareSheet(url: file.url) }
            .sheet(item: $editedLine) { line in LineEditor(line: line) { controller.updateLine(line.id, text: $0) } }
            .alert(L10n.tr("重點標記", "Bookmark"), isPresented: $showBookmark) {
                TextField(L10n.tr("簡短註記（可留白）", "Short note (optional)"), text: $bookmarkNote)
                Button(L10n.tr("加入", "Add")) { controller.bookmark(bookmarkNote); bookmarkNote = "" }
                Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            } message: { Text(L10n.tr("標記會使用目前的錄音時間。", "Bookmark will use the current timestamp.")) }
            .alert(L10n.tr("需要留意", "Notice"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
                Button(L10n.tr("知道了", "OK")) { controller.errorMessage = nil }
            } message: { Text(controller.errorMessage ?? "") }
        }
        .preferredColorScheme(.light)
        .task { if automaticallyCheckUpdates { await updates.check() } }
        .onChange(of: pip.active) { value in controller.pipActive = value && !pip.paused }
        .onChange(of: pip.paused) { value in controller.pipActive = pip.active && !value }
        .onChange(of: controller.isRecording) { recording in
            if recording { pip.startAutomaticallyWhenReady(recording: true) }
        }
        .onAppear {
            pip.restoreUserInterface = {
                navigation.restoreCurrentLectureTranscript(activeLectureID: controller.session?.id)
            }
        }
    }

    private var appleLanguageControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.tr("Apple 辨識語言", "Apple Speech Language"), selection: Binding(get: {
                RecognitionLanguage.primary(controller.language) ?? "zh"
            }, set: { controller.selectAppleLanguage($0) })) {
                Text(L10n.tr("中文", "Chinese")).tag("zh")
                Text("English").tag("en")
            }.pickerStyle(.segmented).accessibilityIdentifier("liveAppleLanguage")
                .disabled(controller.isBusy || controller.isSummarizing || controller.pendingAppleLanguage != nil
                    || (!controller.isRecording && !controller.canManageSessions))
            if let pending = controller.pendingAppleLanguage {
                Text(L10n.tr("切換為\(pending == "en" ? "英文" : "中文")中 · 錄音持續保存", "Switching to \(pending == "en" ? "English" : "Chinese")…"))
                    .font(.caption).foregroundStyle(gold)
            } else {
                Text(L10n.tr("錄音中可切換；請在語言改變前或停頓處按下。", "Switchable during recording; tap before language changes or at pauses."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recordingHeader: some View {
        VStack(spacing: 12) {
            TextField(L10n.tr("課堂名稱", "Lecture Title"), text: $controller.title)
                .font(.headline).multilineTextAlignment(.center)
                .onChange(of: controller.title) { value in
                    if controller.session != nil { controller.rename(value) }
                }
            HStack(spacing: 10) {
                if controller.isRecording { Circle().fill(red).frame(width: 10, height: 10) }
                Text(TranscriptExport.clock(controller.duration))
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityLabel(L10n.tr("錄音時間 \(TranscriptExport.clock(controller.duration))", "Duration \(TranscriptExport.clock(controller.duration))"))
            }
            if controller.usesAppleSpeech {
                appleLanguageControls.frame(maxWidth: 560)
            } else {
            Picker(L10n.tr("辨識語言", "Language"), selection: Binding(get: {
                RecognitionLanguage.isMixed(controller.language) ? "mixed" : controller.language
            }, set: { value in
                controller.setLanguage(value == "mixed" && controller.language == "en" ? "mixed-en" : value)
            })) {
                Text(L10n.tr("自動", "Auto")).tag("auto")
                Text(L10n.tr("中英夾雜", "Mixed Zh/En")).tag("mixed")
                Text(L10n.tr("中文", "Chinese")).tag("zh")
                Text(L10n.tr("英文", "English")).tag("en")
            }.pickerStyle(.segmented).disabled(!controller.canManageSessions).frame(maxWidth: 560)
            if RecognitionLanguage.isMixed(controller.language) {
                Picker(L10n.tr("混說主要語言", "Primary Language"), selection: Binding(get: {
                    RecognitionLanguage.primary(controller.language) ?? "zh"
                }, set: { controller.setLanguage($0 == "en" ? "mixed-en" : "mixed") })) {
                    Text(L10n.tr("中文為主", "Primary Chinese")).tag("zh")
                    Text(L10n.tr("英文為主", "Primary English")).tag("en")
                }.pickerStyle(.segmented).disabled(!controller.canManageSessions).frame(maxWidth: 400)
                    .accessibilityIdentifier("mixedPrimaryLanguage")
            }
            if controller.usesSenseVoice {
                Text(L10n.tr("SenseVoice 使用前後重疊音訊更新草稿，再按停頓或視窗上限定稿。低音量也送入模型；錄後可從匯出選單另存重新轉錄。重疊參數與接縫準確度仍需真機驗證。", "SenseVoice updates drafts using overlapping audio, finalizing on pauses or window boundaries. Low volume audio also processed."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
            Text(RecognitionLanguage.isMixed(controller.language) ? (controller.usesAppleSpeech ? L10n.tr("Apple 每次以一個主要語言辨識，不保證中英混說。單語課堂請選中文或英文。", "Apple Speech transcribes with one primary language at a time. Select Chinese or English for monolingual lectures.") : L10n.tr("依實際主要語言辨識；混說準確率仍需核對。停止後可切換。", "Transcribes based on actual primary language; switchable when paused.")) : L10n.tr("指定主要語言有助辨識。Apple 引擎使用系統支援的語言資源。", "Specifying primary language helps recognition."))
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
                    .accessibilityLabel(controller.audioSource == .deviceAudio ? L10n.tr("裝置聲音音量", "Device audio volume") : L10n.tr("麥克風音量", "Microphone volume"))
            }
        }
    }

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.tr("即時字幕", "Live Captions"), systemImage: "captions.bubble.fill").font(.caption.bold())
                Spacer()
                Text(controller.displayedDraft.isEmpty ? L10n.tr("已確認", "Confirmed") : L10n.tr("辨識中 · 可修正", "Recognizing · Draft")).font(.caption)
            }.foregroundStyle(.white.opacity(0.7))
            Text(controller.caption.isEmpty ? L10n.tr("等待語音…", "Waiting for speech…") : controller.caption)
                .font(.system(size: captionFontSize, weight: .medium)).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
            if controller.translationEnabled && !controller.translationCaption.isEmpty {
                Text(controller.translationCaption).font(.system(size: translationFontSize)).lineLimit(4)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.45))
                if !controller.validTranslatedDraft.isEmpty {
                    Text(L10n.tr("翻譯草稿 · 稍晚於原文更新", "Draft translation · Updates after speech")).font(.caption2).foregroundStyle(.white.opacity(0.65))
                }
            }
        }.padding(16).background(Color(red: 0.13, green: 0.13, blue: 0.14))
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $controller.translationEnabled) {
                Label(L10n.tr("即時翻譯字幕", "Live Translation Captions"), systemImage: "captions.bubble.fill").font(.headline)
            }.tint(.green).accessibilityIdentifier("translationToggle")
            Text(controller.translationStatus).font(.caption).foregroundStyle(.secondary)
            if controller.translationEnabled {
                Text((controller.translationSource == "ja" ? L10n.tr("日文 → 繁體中文", "Japanese → Traditional Chinese") : L10n.tr("英文 → 繁體中文", "English → Traditional Chinese")) + " · " + L10n.tr("先顯示草稿，再保存確認段落；翻譯會比原文稍晚。", "Draft shown first, then finalized. Translation follows original speech."))
                    .font(.caption).foregroundStyle(gold)
                Button(L10n.tr("重試翻譯", "Retry Translation")) { controller.restartTranslation() }.font(.caption)
            }
        }.padding(16).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
    }

    private func transcriptPane(translated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(translated ? L10n.tr("中文翻譯", "Translation") : L10n.tr("即時逐字稿", "Live Transcript"),
                      systemImage: translated ? "character.bubble" : "waveform")
                    .font(.headline).foregroundStyle(translated ? gold : ink)
                Spacer()
                Text(translated ? L10n.tr("繁體中文", "Traditional Chinese") : L10n.tr("原文", "Original")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if controller.session?.lines.isEmpty != false && controller.displayedDraft.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: translated ? "character.bubble" : "waveform")
                                    .font(.system(size: 30)).foregroundStyle(gold.opacity(0.7))
                                Text(translated ? L10n.tr("讓理解跟上對話", "Follow conversations with ease") : L10n.tr("把注意力留給課堂", "Focus on the lecture")).font(.title3.bold())
                                Text(translated ? L10n.tr("英語會逐段翻成中文，中文內容保留原文。首次使用請允許下載翻譯語言。", "English will be translated into Chinese. Please allow downloading language models on first run.") : L10n.tr("按下開始錄音，文字會在這裡逐步出現。灰色草稿可能修正，確認後自動保存。", "Tap start to see speech transcribed in real time. Drafts are finalized and saved automatically."))
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
                                        Button(L10n.tr("聽這段原音／核對切點", "Play audio / Review split")) { reviewedLine = line }.font(.caption).disabled(!controller.canManageSessions)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if !translated {
                                        Button(L10n.tr("編輯文字", "Edit text")) { editedLine = line }.disabled(!controller.canManageSessions)
                                        if line.userEdited == true { Button(L10n.tr("解除手動修改鎖定", "Unlock manual edit")) { controller.unlockLine(line.id) }.disabled(!controller.canManageSessions) }
                                        if let names = controller.session?.speakerNames {
                                            ForEach(names.keys.sorted(), id: \.self) { id in
                                                Button(L10n.tr("設為 \(names[id] ?? id)", "Assign to \(names[id] ?? id)")) { controller.assignSpeaker(line.id, speaker: id) }.disabled(!controller.canManageSessions)
                                            }
                                            Button(L10n.tr("講者未確認", "Unconfirmed speaker")) { controller.assignSpeaker(line.id, speaker: "unconfirmed") }.disabled(!controller.canManageSessions)
                                        }
                                    }
                                    Button(L10n.tr("複製", "Copy")) { UIPasteboard.general.string = text }
                                }
                            }
                        }
                        let draft = translated ? controller.validTranslatedDraft : controller.displayedDraft
                        if controller.search.isEmpty && !draft.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tr("草稿 · 可能更新", "Draft · Updating")).font(.caption).foregroundStyle(gold)
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
            HStack(spacing: 12) {
                Button {
                    if let url = controller.exportNotes(translation: true) { sharedFile = SharedFile(url: url) }
                } label: { Label(L10n.tr("分享翻譯", "Share Translation"), systemImage: "square.and.arrow.up") }
                    .disabled(controller.session?.translations?.isEmpty != false)
                Spacer()
                Button {
                    showMinutes = true
                } label: { Label(L10n.tr("會議紀錄", "Notes"), systemImage: "doc.text").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.session?.lines.isEmpty != false)
            }.font(.callout)

            if !controller.isRecording && controller.session == nil {
                HStack(spacing: 16) {
                    Picker(L10n.tr("音訊來源", "Audio Source"), selection: $controller.audioSource) {
                        Label(AudioInputSource.microphone.displayName, systemImage: "mic").tag(AudioInputSource.microphone)
                        Label(AudioInputSource.deviceAudio.displayName, systemImage: "speaker.wave.2").tag(AudioInputSource.deviceAudio)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    if controller.audioSource == .deviceAudio {
                        if !DeviceAudioAvailability.isSupported {
                            Text(DeviceAudioAvailability.unavailableReason)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else {
                            Picker(L10n.tr("儲存模式", "Session Storage"), selection: $controller.sessionStorageMode) {
                                Text(SessionStorageMode.liveOnly.displayName).tag(SessionStorageMode.liveOnly)
                                Text(SessionStorageMode.saveTranscript.displayName).tag(SessionStorageMode.saveTranscript)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 320)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        if controller.audioSource == .deviceAudio {
                            if controller.isRecording {
                                await controller.endLecture()
                                pip.stop()
                            } else {
                                await controller.start()
                            }
                        } else {
                            if controller.isRecording { await controller.pause() }
                            else if controller.session?.hasPendingAudio == true { await controller.recover() }
                            else { await controller.start() }
                        }
                    }
                } label: {
                    Label(recordLabel, systemImage: controller.isRecording
                        ? (controller.audioSource == .deviceAudio ? "stop.fill" : "pause.fill")
                        : (controller.audioSource == .deviceAudio ? "captions.bubble.fill" : "mic.fill"))
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(red).clipShape(Capsule())
                .disabled(controller.isBusy || controller.isSummarizing || (!controller.isRecording && !controller.canStart && controller.session?.hasPendingAudio != true))

                if controller.session != nil && controller.audioSource == .microphone {
                    Button {
                        Task {
                            await controller.endLecture()
                            pip.stop()
                        }
                    } label: {
                        Image(systemName: "stop.fill").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .disabled(controller.isBusy)
                    .accessibilityLabel(L10n.tr("結束課堂", "End Lecture"))
                }
                Button { showBookmark = true } label: {
                    Image(systemName: "bookmark").font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.bordered).clipShape(Circle()).disabled(controller.session == nil)
                    .accessibilityLabel(L10n.tr("加入重點標記", "Add Bookmark"))
            }
            if controller.isSummarizing {
                Text(controller.summaryStatus).font(.caption).foregroundStyle(gold)
            } else if let saved = controller.lastSaved {
                Text(L10n.tr("已儲存到本機 · \(saved.formatted(date: .omitted, time: .standard))", "Saved locally · \(saved.formatted(date: .omitted, time: .standard))"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 1200).frame(maxWidth: .infinity).background(paper)
    }
    private var recordLabel: String {
        if controller.isRecording {
            return controller.audioSource == .deviceAudio ? L10n.tr("停止即時字幕", "Stop Live Captions") : L10n.tr("暫停", "Pause")
        }
        if controller.audioSource == .deviceAudio {
            return L10n.tr("開始即時字幕", "Start Live Captions")
        }
        if controller.session?.hasPendingAudio == true { return L10n.tr("補辨識", "Catch Up") }
        return controller.session == nil ? L10n.tr("開始錄音", "Start Recording") : L10n.tr("繼續錄音", "Resume Recording")
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                // SECTION 0: 音訊來源與儲存模式
                Section(L10n.tr("音訊來源與儲存模式", "Audio Source & Session Storage")) {
                    Picker(L10n.tr("音訊來源", "Audio Source"), selection: $controller.audioSource) {
                        Text(AudioInputSource.microphone.displayName).tag(AudioInputSource.microphone)
                        Text(AudioInputSource.deviceAudio.displayName).tag(AudioInputSource.deviceAudio)
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.isRecording || controller.isBusy)

                    if controller.audioSource == .deviceAudio {
                        if !DeviceAudioAvailability.isSupported {
                            Text(DeviceAudioAvailability.unavailableReason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Picker(L10n.tr("儲存模式", "Session Storage"), selection: $controller.sessionStorageMode) {
                                Text(SessionStorageMode.liveOnly.displayName).tag(SessionStorageMode.liveOnly)
                                Text(SessionStorageMode.saveTranscript.displayName).tag(SessionStorageMode.saveTranscript)
                            }
                            .pickerStyle(.segmented)
                            .disabled(controller.isRecording || controller.isBusy)

                            Text(controller.sessionStorageMode == .liveOnly
                                ? L10n.tr("「僅即時顯示」在結束後不保留錄音與文字紀錄；無任何檔案寫入磁碟。", "'Live Only' keeps no recording or transcript after session ends; no files written to disk.")
                                : L10n.tr("「保留逐字稿」在結束後僅儲存文字與翻譯紀錄，不儲存任何裝置聲音錄音檔。", "'Save Transcript' saves text and translations only, without saving any audio recording file."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.tr("麥克風模式會將聲音保存在本機，供事後重播或再次辨識。", "Microphone mode saves audio locally for playback and re-transcription."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // SECTION 1: 辨識核心 (置頂)
                Section(L10n.tr("1. 辨識核心", "1. Recognition Engine")) {
                    Picker(L10n.tr("辨識引擎", "Speech Engine"), selection: Binding(get: { controller.recognitionEngine }, set: { value in
                        controller.setRecognitionEngine(value)
                        if value == "apple" && RecognitionLanguage.primary(controller.language) == nil { controller.setLanguage("zh") }
                        if value == "sensevoice" { controller.setLanguage("auto") }
                    })) {
                        Text(L10n.tr("Apple Speech · 系統內建 · 最快／最省電", "Apple Speech · System Built-in · Fastest / Efficient")).tag("apple")
                        Text(L10n.tr("WhisperKit · Turbo 等模型", "WhisperKit · Models")).tag("whisper")
                        Text(L10n.tr("SenseVoice · 中英混合／多語快速", "SenseVoice · Mixed-language / Multilingual Fast")).tag("sensevoice")
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

                    if controller.usesAppleSpeech {
                        Picker(L10n.tr("辨識語言", "Recognition Language"), selection: Binding(
                            get: { RecognitionLanguage.primary(controller.language) ?? "zh" },
                            set: { controller.setLanguage($0) }
                        )) {
                            Text(L10n.tr("繁體中文", "Traditional Chinese")).tag("zh")
                            Text("English").tag("en")
                        }
                        Text(L10n.tr("Apple Speech 每次使用一個主要語言；中英混說請改用 SenseVoice。", "Apple Speech uses one selected locale. Use SenseVoice for mixed Chinese and English."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.tr("辨識語言", "Recognition Language"), selection: Binding(get: {
                            RecognitionLanguage.isMixed(controller.language) ? "mixed" : controller.language
                        }, set: { controller.setLanguage($0) })) {
                            if controller.usesSenseVoice { Text(L10n.tr("自動語言", "Automatic Language")).tag("auto") }
                            Text(L10n.tr("中英混合", "Mixed Chinese / English")).tag("mixed")
                            Text(L10n.tr("中文", "Chinese")).tag("zh")
                            Text(L10n.tr("英文", "English")).tag("en")
                        }
                    }

                    Picker(L10n.tr("翻譯來源語言", "Translation Source"), selection: Binding(get: { controller.translationSource }, set: { controller.setTranslationSource($0) })) {
                        Text(L10n.tr("英文 → 繁中", "English → Chinese")).tag("en")
                        Text(L10n.tr("日文 → 繁中", "Japanese → Chinese")).tag("ja")
                    }

                    let cap = EngineCapability.isSupported(engine: controller.recognitionEngine, language: controller.language)
                    Text(cap.detail)
                        .font(.caption).foregroundStyle(cap.supported ? Color.secondary : Color.orange)
                }

                // SECTION 4: PiP 字幕
                Section(L10n.tr("4. 子母字幕", "4. PiP Captions")) {
                    PiPInlinePreview(settings: pipSettings)
                    Toggle(L10n.tr("自動開啟子母字幕", "Automatically Start PiP Captions"), isOn: $pipSettings.autoStart)
                    Picker(L10n.tr("字幕顯示模式", "Display Mode"), selection: $pipSettings.captionMode) {
                        ForEach(PiPDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker(L10n.tr("字幕比例", "Aspect Ratio"), selection: $pipSettings.aspectRatio) {
                        ForEach(PiPAspectRatio.allCases) { ratio in
                            Text(ratio.title).tag(ratio)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text(L10n.tr("字幕大小：\(Int(pipSettings.fontScale * 100))%", "Caption Size: \(Int(pipSettings.fontScale * 100))%"))
                        Slider(value: $pipSettings.fontScale, in: 0.75...1.5, step: 0.05)
                            .accessibilityIdentifier("pipFontScale")
                    }
                    Picker(L10n.tr("文字對齊", "Text Alignment"), selection: $pipSettings.alignment) {
                        ForEach(PiPTextAlignment.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L10n.tr("字幕位置", "Caption Position"), selection: $pipSettings.verticalPosition) {
                        ForEach(PiPVerticalPosition.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L10n.tr("原文與翻譯間距", "Original / Translation Gap"), selection: $pipSettings.gap) {
                        ForEach(PiPCaptionGap.allCases) { Text($0.title).tag($0) }
                    }
                    Button(L10n.tr("在子母畫面中預覽", "Preview in Picture in Picture")) {
                        pip.setSamplePreview(!controller.isRecording)
                        controller.pipEnabled = true
                        pip.start(recording: controller.isRecording)
                    }
                    .accessibilityIdentifier("previewPiP")
                    Button(L10n.tr("還原子母字幕預設設定", "Reset PiP Caption Settings")) {
                        pipSettings.reset()
                    }
                    .accessibilityIdentifier("resetPiP")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("原文字幕大小：\(Int(captionFontSize))", "Original Font Size: \(Int(captionFontSize))"))
                        Slider(value: $captionFontSize, in: 14...48, step: 1)
                            .accessibilityLabel(L10n.tr("原文字幕大小", "Original Caption Font Size"))
                            .accessibilityIdentifier("原文字幕大小")
                        Text(L10n.tr("翻譯字幕大小：\(Int(translationFontSize))", "Translation Font Size: \(Int(translationFontSize))"))
                        Slider(value: $translationFontSize, in: 14...48, step: 1)
                            .accessibilityLabel(L10n.tr("翻譯字幕大小", "Translation Caption Font Size"))
                            .accessibilityIdentifier("翻譯字幕大小")
                        Text(L10n.tr("逐字稿字級：\(Int(transcriptFontSize))", "Transcript Font Size: \(Int(transcriptFontSize))"))
                        Slider(value: $transcriptFontSize, in: 14...36, step: 1)
                            .accessibilityLabel(L10n.tr("逐字稿字級", "Transcript Font Size"))
                            .accessibilityIdentifier("逐字稿大小")
                    }
                }

                // SECTION 5: 即時動態與系統整合
                Section(L10n.tr("5. 即時動態與系統整合", "5. Live Activity & System Integration")) {
                    Toggle(L10n.tr("啟用鎖定畫面即時動態", "Enable Lock Screen Live Activity"), isOn: Binding(
                        get: { LiveActivityCoordinator.shared.liveActivityEnabled },
                        set: { LiveActivityCoordinator.shared.liveActivityEnabled = $0 }
                    ))

                    if !LiveActivityCoordinator.shared.isSupported {
                        Text(L10n.tr("此裝置或系統版本未啟用即時動態支援。", "Live Activities not available or disabled on this device."))
                            .font(.caption).foregroundStyle(.orange)
                    }

                    Text(L10n.tr("錄音時在鎖定畫面與 iPhone 動態島顯示錄音時間、最新原文與繁中翻譯。100% 本機 ActivityKit 更新，不使用 APNs 或 Push。", "Shows recording timer, latest original, and translation on Lock Screen and Dynamic Island. 100% local ActivityKit."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 6: 模型與資源管理
                Section(controller.usesAppleSpeech ? L10n.tr("6. 系統資源", "6. System Resources") : L10n.tr("6. 可下載 App 模型", "6. Downloadable App Models")) {
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
                        if controller.usesAppleSpeech {
                            Label(controller.loadedModel == "apple" ? L10n.tr("Apple Speech · 系統內建 · 已就緒", "Apple Speech · System Built-in · Ready") : L10n.tr("準備語音資源", "Prepare Speech Resource"), systemImage: "waveform")
                        } else {
                            Label(controller.loadedModel != nil ? L10n.tr("模型已就緒", "Model Ready") : L10n.tr("下載 / 載入模型", "Download / Load Model"), systemImage: "arrow.down.circle")
                        }
                    }
                    .accessibilityLabel(L10n.tr("載入模型", "Load Model"))
                    .accessibilityIdentifier("prepareSpeechResource")
                    .disabled(!controller.canManageSessions)

                    Text(controller.usesAppleSpeech
                         ? L10n.tr("開始錄音時會自動檢查 Apple Speech 系統資源；不必先在設定中下載。", "Apple Speech system resources are checked automatically when recording starts.")
                         : L10n.tr("App 模型儲存於 Application Support / SpeechModels，既有模型不會因更新而重新下載。", "App models remain in Application Support / SpeechModels and are retained across updates."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 7: 錄音品質與儲存
                Section(L10n.tr("7. 錄音品質與儲存", "7. Audio Quality & Storage")) {
                    Picker(L10n.tr("儲存品質", "Audio Quality"), selection: Binding(get: { controller.recordingQuality }, set: { controller.setRecordingQuality($0) })) {
                        ForEach(RecordingQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("recordingQuality")
                    .disabled(!controller.canManageSessions)

                    Text(L10n.tr("只影響接下來的新錄音片段。辨識使用未經 AAC 壓縮的 16 kHz 單聲道音訊；停止並補完辨識後才壓縮保存。", "Affects new segments. Raw 16 kHz PCM used during capture; compressed upon completion."))
                        .font(.caption)
                }

                // SECTION 8: 課程詞彙 (Beta) 與專有名詞提示
                Section(L10n.tr("8. 課程詞彙 (Beta) 與專有名詞提示", "8. Course Vocabulary (Beta) & Prompt")) {
                    Button {
                        showCourseVocabulary = true
                    } label: {
                        HStack {
                            Label(L10n.tr("課程詞彙 (Beta)", "Course Vocabulary (Beta)"), systemImage: "text.book.closed")
                            Spacer()
                            Text("\(courseVocabulary.entries.count)/100")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.tr("協助辨識保留技術詞與課程專有名詞（支援 Apple Speech 與 SenseVoice）。", "Helps recognition preserve technical and course-specific terms (supports Apple Speech & SenseVoice)."))
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    Text(L10n.tr("WhisperKit 提示詞：", "WhisperKit Prompt Words:"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(L10n.tr("例如：CRISPR、Cas9、gene editing", "e.g. CRISPR, Cas9, gene editing"), text: $controller.vocabulary, axis: .vertical)
                        .lineLimit(2...4).disabled(controller.settingsLocked || !controller.usesWhisper)
                        .onChange(of: controller.vocabulary) { value in
                            if value.count > 500 { controller.vocabulary = String(value.prefix(500)) }
                        }
                    Text(L10n.tr("自訂專有名詞提示 WhisperKit 解碼偏好，最多 500 字元。", "Custom prompt words hinting WhisperKit decoding, max 500 characters."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // SECTION 9: 智慧筆記
                Section(L10n.tr("9. 智慧筆記與 AI 整理", "9. Smart Notes & Summary")) {
                    Text(L10n.tr("AI 整理使用 iPadOS 26 的 Apple Intelligence。若未啟用將產生具時間戳之原文整理。", "AI notes use on-device Apple Intelligence or structured timeline outline."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("SenseVoice 重新轉錄（另存新課堂）", "Retranscribe with SenseVoice (Save As New)")) {
                        showSettings = false
                        Task { await controller.retranscribeRecording() }
                    }.disabled(!controller.canManageSessions || controller.session?.parts.contains { $0.sampleCount > 0 } != true)
                }

                // SECTION 10: 側載簽名維護
                Section(L10n.tr("10. 側載簽名維護", "10. SideStore Self-Refresh")) {
                    SigningExpirationSection()
                }

                // SECTION 11: 關於與版本
                Section(L10n.tr("11. 關於與版本更新", "11. About & Version")) {
                    Text(L10n.tr("目前版本：", "Current Version: ") + updates.current)
                    Toggle(L10n.tr("開啟 App 時檢查更新", "Check updates on launch"), isOn: $automaticallyCheckUpdates)
                    Button(L10n.tr("檢查更新", "Check for Updates")) { Task { await updates.check() } }
                        .accessibilityLabel(L10n.tr("檢查更新", "Check for Updates"))
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

                // SECTION 12: 裝置聲音診斷與觀測
                DeviceAudioDiagnosticsView(controller: controller)
            }
            .navigationTitle(L10n.tr("錄音設定", "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done")) { showSettings = false }
                        .accessibilityLabel(L10n.tr("完成", "Done"))
                        .accessibilityIdentifier("完成")
                }
            }
        }
    }

    private var minutesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(L10n.tr("把對話整理成可回顧的記錄", "Organize conversations into reviewable notes"), systemImage: "doc.text")
                        .font(.title3.bold())
                    Text(L10n.tr("停止錄音並完成補辨識後，可用裝置端 AI 整理重點、明確決議與待辦。結果需要對照原文確認。", "After recording, use on-device AI to summarize highlights, decisions, and todos. Please verify results against the original transcript."))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("整理偏好（在這台裝置保存，最多 800 字）", "Summary Prompt (Saved on this device, max 800 chars)")).font(.headline)
                    TextEditor(text: $controller.notesPrompt).frame(minHeight: 100)
                        .disabled(controller.isSummarizing)
                        .onChange(of: controller.notesPrompt) { _ in controller.saveNotesPrompt() }
                    Button(L10n.tr("恢復預設提示詞", "Restore Default Prompt")) {
                        controller.notesPrompt = "以繁體中文整理重點、決議、待辦；保留英文術語和來源時間戳。"; controller.saveNotesPrompt()
                    }.disabled(controller.isSummarizing)
                    Button(controller.session?.minutes == nil ? L10n.tr("產生會議紀錄", "Generate Notes") : L10n.tr("重新整理", "Regenerate Notes")) {
                        Task { await controller.generateMinutes() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!controller.canManageSessions || controller.session?.hasPendingAudio == true)
                    Button(L10n.tr("使用原文整理（不需要 Apple Intelligence）", "Use Outline (No Apple Intelligence Required)")) { controller.makeOutline() }
                        .disabled(!controller.canManageSessions)
                    if controller.isSummarizing { ProgressView(controller.summaryStatus) }
                    else if !controller.summaryStatus.isEmpty { Text(controller.summaryStatus).font(.caption) }
                    if let current = controller.session, let notes = current.minutes {
                        if let prompt = current.minutesPrompt { Text(L10n.tr("本次整理偏好：", "Current prompt: ") + prompt).font(.caption).foregroundStyle(.secondary) }
                        if !current.minutesAreCurrent {
                            Label(L10n.tr("逐字稿已更新，請重新整理", "Transcript updated; please regenerate"), systemImage: "arrow.clockwise").foregroundStyle(.orange)
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
            }.background(paper).navigationTitle(L10n.tr("會議紀錄", "Meeting Notes"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("完成", "Done")) { showMinutes = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: (controller.session?.minutesAreCurrent == false ? L10n.tr("注意：逐字稿已有更新，這是先前整理的版本。\n\n", "Note: Transcript has been updated; this is a previous summary.\n\n") : "") + (controller.session?.minutes ?? "")) { Label(L10n.tr("分享", "Share"), systemImage: "square.and.arrow.up") }
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
            .alert(L10n.tr("重新命名課堂", "Rename Lecture"), isPresented: $showRenameAlert) {
                TextField(L10n.tr("課堂名稱", "Lecture Title"), text: $renameTitle)
                Button(L10n.tr("儲存", "Save")) {
                    if let s = renamingSession {
                        controller.renameLecture(s.id, title: renameTitle)
                    }
                    renamingSession = nil
                }
                Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                    renamingSession = nil
                }
            }
            .confirmationDialog(L10n.tr("刪除這堂課？", "Delete this lecture?"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button(L10n.tr("刪除錄音與所有逐字稿", "Delete Recording & Transcripts"), role: .destructive) {
                    if let item = pendingDeletion { controller.deleteLecture(item.id) }
                    pendingDeletion = nil
                }
                Button(L10n.tr("取消", "Cancel"), role: .cancel) { pendingDeletion = nil }
            } message: { Text(L10n.tr("將刪除「\(pendingDeletion?.title ?? "")」的錄音、所有版本逐字稿、標記與本機匯出檔，無法復原。已分享出去的檔案不受影響。", "Will permanently delete recording, all transcript versions, bookmarks, and local exports for '\(pendingDeletion?.title ?? "")'.")) }
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
            TextEditor(text: $text).padding().navigationTitle(L10n.tr("編輯逐字稿", "Edit Transcript"))
                .onAppear { text = line.text }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("儲存", "Save")) { save(text); dismiss() } }
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

// MARK: - Course Vocabulary Sheet

struct CourseVocabularySheet: View {
    @ObservedObject var vocabulary = CourseVocabulary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAddDialog = false
    @State private var newCanonical = ""
    @State private var newAliases = ""
    @State private var editingEntry: VocabularyEntry? = nil
    @State private var editCanonical = ""
    @State private var editAliases = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.tr("協助辨識保留技術詞與課程專有名詞。", "Helps recognition preserve technical and course-specific terms."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.tr("詞彙清單（上限 100 筆，目前 \(vocabulary.entries.count) 筆）", "Vocabulary List (Max 100, Current: \(vocabulary.entries.count))")) {
                    if vocabulary.entries.isEmpty {
                        Text(L10n.tr("尚未加入課程詞彙。點擊右上角「+」即可新增專門術語。", "No course vocabulary yet. Tap '+' to add technical terms."))
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(vocabulary.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.canonical)
                                    .font(.headline)
                                if !entry.aliases.isEmpty {
                                    Text(L10n.tr("別名：", "Aliases: ") + entry.aliasesDisplayString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingEntry = entry
                                editCanonical = entry.canonical
                                editAliases = entry.aliasesDisplayString
                            }
                        }
                        .onDelete { offsets in
                            vocabulary.deleteEntries(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("課程詞彙 (Beta)", "Course Vocabulary (Beta)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("關閉", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newCanonical = ""
                        newAliases = ""
                        showAddDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(vocabulary.entries.count >= CourseVocabulary.maxEntriesCount)
                }
            }
            .sheet(isPresented: $showAddDialog) {
                NavigationStack {
                    Form {
                        Section(L10n.tr("標準專有名詞 (Canonical)", "Canonical Term")) {
                            TextField(L10n.tr("例如：nuScenes、Q-Former", "e.g. nuScenes, Q-Former"), text: $newCanonical)
                        }
                        Section(L10n.tr("識別別名（以逗號分隔）", "Aliases (Comma separated)")) {
                            TextField(L10n.tr("例如：new scenes, nu scenes", "e.g. new scenes, nu scenes"), text: $newAliases)
                        }
                    }
                    .navigationTitle(L10n.tr("新增課程詞彙", "Add Vocabulary"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("取消", "Cancel")) { showAddDialog = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("儲存", "Save")) {
                                let aliases = newAliases.split(separator: ",").map { String($0) }
                                vocabulary.addEntry(canonical: newCanonical, aliases: aliases)
                                showAddDialog = false
                            }
                            .disabled(newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .sheet(item: $editingEntry) { entry in
                NavigationStack {
                    Form {
                        Section(L10n.tr("標準專有名詞 (Canonical)", "Canonical Term")) {
                            TextField(L10n.tr("例如：nuScenes", "e.g. nuScenes"), text: $editCanonical)
                        }
                        Section(L10n.tr("識別別名（以逗號分隔）", "Aliases (Comma separated)")) {
                            TextField(L10n.tr("例如：new scenes, nu scenes", "e.g. new scenes, nu scenes"), text: $editAliases)
                        }
                    }
                    .navigationTitle(L10n.tr("編輯課程詞彙", "Edit Vocabulary"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("取消", "Cancel")) { editingEntry = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("儲存", "Save")) {
                                let aliases = editAliases.split(separator: ",").map { String($0) }
                                vocabulary.updateEntry(id: entry.id, canonical: editCanonical, aliases: aliases)
                                editingEntry = nil
                            }
                            .disabled(editCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Device Audio Diagnostics View

struct DeviceAudioDiagnosticsView: View {
    @ObservedObject var manager = DeviceAudioCaptureManager.shared
    @ObservedObject var controller: LectureController
    @State private var copied = false

    var body: some View {
        Section(L10n.tr("12. 裝置聲音診斷與觀測", "12. Device Audio Diagnostics")) {
            let diag = manager.diagnostics
            HStack {
                Text(L10n.tr("版本編號", "App Version"))
                Spacer()
                Text(diag.appVersion).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("系統版本", "OS Version"))
                Spacer()
                Text(diag.osVersion).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("裝置聲音支援", "Device Audio Support"))
                Spacer()
                Text(DeviceAudioAvailability.isSupported ? L10n.tr("支援", "Supported") : L10n.tr("不支援 (需 iOS 27+)", "Unsupported (Requires iOS 27+)"))
                    .bold()
                    .foregroundStyle(DeviceAudioAvailability.isSupported ? .green : .orange)
            }
            HStack {
                Text(L10n.tr("擷取狀態", "Capture Status"))
                Spacer()
                Text(manager.isCapturing ? L10n.tr("擷取中", "Capturing") : L10n.tr("閒置", "Idle"))
                    .foregroundStyle(manager.isCapturing ? .green : .secondary)
            }
            HStack {
                Text(L10n.tr("音訊緩衝流接收", "Audio Buffers Receiving"))
                Spacer()
                Text(diag.audioBuffersReceiving ? L10n.tr("接收中", "Receiving") : L10n.tr("無", "None"))
                    .foregroundStyle(diag.audioBuffersReceiving ? .green : .secondary)
            }
            HStack {
                Text(L10n.tr("累計接收緩衝區", "Total Buffers Received"))
                Spacer()
                Text("\(diag.totalBuffersReceived)")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text(L10n.tr("首個音訊封包延遲", "First Buffer Latency"))
                Spacer()
                Text(diag.firstBufferLatencyText)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text(L10n.tr("取樣率與聲道", "Sample Rate & Channels"))
                Spacer()
                Text("\(Int(diag.sampleRate)) Hz · \(diag.channelCount)ch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("轉換格式", "Target PCM Format"))
                Spacer()
                Text("16kHz Mono Float32")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("最近緩衝區間隔", "Last Buffer Age"))
                Spacer()
                Text(diag.lastBufferAgeText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = diag.lastError {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("最近錯誤：", "Last Error:"))
                        .font(.caption).foregroundStyle(.red)
                    Text(error)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button {
                manager.updateEnvironmentDiagnostics(engine: controller.usesAppleSpeech ? "Apple Speech" : (controller.usesSenseVoice ? "SenseVoice" : "WhisperKit"))
                _ = manager.copyDiagnostics()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                HStack {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(copied ? L10n.tr("已複製診斷資訊", "Copied Diagnostics") : L10n.tr("複製診斷資訊", "Copy Diagnostics"))
                }
            }
        }
    }
}

