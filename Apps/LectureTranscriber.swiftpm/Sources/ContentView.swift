import SwiftUI
import UIKit

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct ContentView: View {
    @ObservedObject var controller: LectureController
    @State private var showHistory = false
    @State private var showBookmark = false
    @State private var bookmarkNote = ""
    @State private var sharedFile: SharedFile?
    @State private var editedLine: TranscriptLine?
    @State private var followLatest = true
    @State private var pendingDeletion: LectureSession?
    private let ink = Color(red: 0.09, green: 0.20, blue: 0.24)
    private let teal = Color(red: 0.02, green: 0.43, blue: 0.43)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                transcript
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("課堂逐字稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { controller.reloadHistory(); showHistory = true } label: {
                        Label("歷史紀錄", systemImage: "books.vertical")
                    }.disabled(!controller.canManageSessions)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { controller.newLecture() } label: { Label("新課堂", systemImage: "square.and.pencil") }
                        .disabled(!controller.canManageSessions)
                    Menu {
                        ForEach(TranscriptFormat.allCases) { format in
                            Button("匯出 \(format.rawValue)") {
                                if let url = controller.export(format) { sharedFile = SharedFile(url: url) }
                            }
                        }
                    } label: { Label("匯出", systemImage: "square.and.arrow.up") }
                    .disabled(controller.session == nil || controller.isBusy || controller.isRecording)
                }
            }
            .tint(teal)
            .sheet(isPresented: $showHistory) { historySheet }
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
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TextField("課堂名稱", text: $controller.title)
                    .font(.title2.bold())
                    .onSubmit { controller.rename(controller.title) }
                    .onChange(of: controller.title) { value in if controller.session != nil { controller.rename(value) } }
                Spacer(minLength: 8)
                Text(TranscriptExport.clock(controller.duration)).font(.title2.monospacedDigit()).foregroundStyle(teal)
                    .accessibilityLabel("錄音時間 \(TranscriptExport.clock(controller.duration))")
            }
            ViewThatFits(in: .horizontal) {
                HStack { settings; Spacer(); modelButton }
                VStack(alignment: .leading) { settings; modelButton }
            }
            DisclosureGroup("課堂專有名詞（選填）") {
                TextField("例如：CRISPR、Cas9、gene editing", text: $controller.vocabulary, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder)
                    .onChange(of: controller.vocabulary) { value in
                        if value.count > 500 { controller.vocabulary = String(value.prefix(500)) }
                    }
                Text("提示模型辨識人名與術語，不保證逐字正確。中文為主、夾雜英文時可選中英混說。")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.footnote).disabled(controller.settingsLocked)
            if controller.isBusy {
                if let fraction = controller.progress { ProgressView(value: fraction) }
                else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack(spacing: 8) {
                Circle().fill(controller.isRecording ? Color.red : teal).frame(width: 8, height: 8)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if controller.isDecoding { ProgressView().controlSize(.small) }
            }
            if controller.isRecording {
                ProgressView(value: Double(controller.level)).tint(teal).accessibilityLabel("麥克風音量")
            }
            HStack {
                if controller.isRecording {
                    Button { Task { await controller.pause() } } label: {
                        Label("暫停並儲存", systemImage: "pause.fill").frame(minHeight: 28)
                    }.buttonStyle(.borderedProminent).disabled(controller.isBusy)
                } else if controller.session?.hasPendingAudio == true {
                    Button { Task { await controller.recover() } } label: {
                        Label("補辨識", systemImage: "arrow.triangle.2.circlepath").frame(minHeight: 28)
                    }.buttonStyle(.borderedProminent).disabled(controller.isBusy)
                } else {
                    Button { Task { await controller.start() } } label: {
                        Label(controller.session == nil ? "開始錄音" : "繼續錄音", systemImage: "mic.fill").frame(minHeight: 28)
                    }.buttonStyle(.borderedProminent).disabled(!controller.canStart)
                }
                Button { controller.bookmark("") } label: { Label("標記", systemImage: "star") }
                    .buttonStyle(.bordered).disabled(controller.session == nil)
                    .contextMenu { Button("加入文字註記") { showBookmark = true } }
                Spacer()
                if controller.pendingSeconds > 5 {
                    Text("尚未定稿 \(Int(controller.pendingSeconds)) 秒").font(.caption).foregroundStyle(.secondary)
                }
            }
            if controller.isRecording, let seconds = controller.lastDecodeSeconds {
                Text(String(format: "本輪辨識 %.1f 秒 · 草稿音訊落後 %.1f 秒", seconds, controller.draftBehindSeconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("保持 App 在前景；錄音時螢幕不會自動鎖定。首次下載完成後可離線辨識。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var settings: some View {
        HStack {
            Picker("語音模型", selection: $controller.model) {
                ForEach(SpeechModel.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("辨識語言", selection: $controller.language) {
                Text("中英混說（中文為主）").tag("mixed")
                Text("自動偵測主語言").tag("auto")
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
        }.pickerStyle(.menu).disabled(controller.settingsLocked)
    }
    private var modelButton: some View {
        Button { Task { await controller.prepareModel() } } label: {
            Label(controller.loadedModel == controller.model ? "模型已就緒" : "載入模型",
                systemImage: controller.loadedModel == controller.model ? "checkmark.circle" : "arrow.down.circle")
        }.disabled(controller.isBusy || controller.isRecording)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋逐字稿", text: $controller.search)
                Toggle("跟隨最新", isOn: $followLatest).font(.caption).fixedSize()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if controller.session?.lines.isEmpty != false && controller.displayedDraft.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(teal)
                                Text("把注意力留給課堂").font(.title2.bold()).foregroundStyle(ink)
                                Text("說話時會先顯示即時草稿，再逐段確認。灰色文字會隨辨識更新，確認後會自動保存。")
                                    .foregroundStyle(.secondary)
                                Text("音訊與逐字稿保留在這台 iPad；錄音約使用 230 MB／小時。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(controller.session?.lines.filter { controller.search.isEmpty || $0.text.localizedCaseInsensitiveContains(controller.search) } ?? []) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(TranscriptExport.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(teal)
                                Text(line.text).font(.body).textSelection(.enabled).lineSpacing(5)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            .contextMenu { Button("編輯文字") { editedLine = line } }
                        }
                        if controller.search.isEmpty, !controller.displayedDraft.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("即時草稿 · 文字可能修正", systemImage: "ellipsis.bubble").font(.caption)
                                Text(controller.displayedDraft).lineSpacing(5).textSelection(.enabled)
                            }.foregroundStyle(.secondary).padding(16)
                        }
                        if let marks = controller.session?.bookmarks, !marks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("重點", systemImage: "star.fill").font(.headline).foregroundStyle(teal)
                                ForEach(marks) { mark in
                                    Text("\(TranscriptExport.clock(mark.seconds))  \(mark.note)").font(.callout)
                                }
                            }.padding(16)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
                .onChange(of: controller.session?.lines.count) { _ in
                    if followLatest && controller.search.isEmpty { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: controller.displayedDraft) { _ in
                    if followLatest && controller.search.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let saved = controller.lastSaved {
                Text("已儲存到本機 · \(saved.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
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
                            if session.hasPendingAudio { Label("有錄音等待補辨識", systemImage: "arrow.clockwise").font(.caption) }
                        }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("刪除 \(session.title)")
                    }
                    .swipeActions(allowsFullSwipe: false) { Button("刪除", role: .destructive) { pendingDeletion = session } }
                    .disabled(!controller.canManageSessions)
                }
            }.navigationTitle("本機課堂")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showHistory = false } } }
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
