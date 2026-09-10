import SwiftUI
import AVFoundation

struct TranscriptReviewView: View {
    @ObservedObject var controller: LectureController
    let line: TranscriptLine
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double
    @State private var end: Double
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var candidate: [TranscriptLine]?
    @State private var shared: SharedFile?
    @State private var temporary: [URL] = []

    init(controller: LectureController, line: TranscriptLine, sessionID: UUID) {
        self.controller = controller; self.line = line; self.sessionID = sessionID
        _start = State(initialValue: line.start)
        _end = State(initialValue: min(controller.duration, max(line.end, line.start + 0.05)))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("原文") {
                    Text(line.text).textSelection(.enabled)
                    Text("\(TranscriptExport.clock(line.start, milliseconds: true)) → \(TranscriptExport.clock(line.end, milliseconds: true))").font(.caption)
                    if line.approximateTiming == true { Text("模型時間為近似位置，請聽原音核對，可擴大播放範圍。") }
                    if line.userEdited == true { Text("此段已有手動修改，已鎖定；可比較新稿，不會自動覆寫。") }
                }
                Section("音訊時間軸（秒）") {
                    Stepper("開始：\(start, specifier: "%.2f")", value: $start, in: 0...max(0, end - 0.05), step: 0.1)
                    Slider(value: $start, in: 0...max(0.05, end - 0.05)).accessibilityLabel("片段開始時間")
                    Stepper("結束：\(end, specifier: "%.2f")", value: $end, in: min(controller.duration, start + 0.05)...max(controller.duration, start + 0.05), step: 0.1)
                    Button("前後多聽半秒") { start = max(0, start - 0.5); end = min(controller.duration, end + 0.5) }
                    Button(playing ? "停止播放" : "播放選定時間（段尾停止）") {
                        if playing { player?.stop(); playing = false }
                        else { Task { await prepare(share: false) } }
                    }.disabled(!controller.canManageSessions)
                    Button("另存這段音訊 WAV") { Task { await prepare(share: true) } }.disabled(!controller.canManageSessions)
                    Button("將選定時間保存為此段切點") {
                        if controller.updateTiming(line.id, start: start, end: end) { dismiss() }
                    }.disabled(!controller.canManageSessions)
                    Text("播放及另存只包含選定區間；完整原音保持不變。拖動／調整時間後請重新播放。")
                        .font(.caption)
                }
                Section("前後文重辨識") {
                    Button("重辨識原段落（保留前後文）") {
                        player?.stop(); playing = false
                        Task { candidate = await controller.reviewRange(start: line.start, end: line.end) }
                    }.disabled(!controller.canManageSessions)
                    if let candidate {
                        Text(candidate.isEmpty ? "這段沒有辨識出文字，原文保留。" : candidate.map(\.text).joined(separator: "\n")).textSelection(.enabled)
                        Button("採用新稿（可復原）") {
                            controller.applyReview(line, replacements: candidate, sessionID: sessionID); dismiss()
                        }.disabled(candidate.isEmpty || line.userEdited == true || !controller.canManageSessions)
                    }
                    if controller.isBusy { ProgressView(controller.status) }
                }
            }
            .navigationTitle("聽原音、核對段落")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(controller.isBusy) } }
            .interactiveDismissDisabled(controller.isBusy)
            .sheet(item: $shared) { ShareSheet(url: $0.url) }
            .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in playing = player?.isPlaying == true }
            .onChange(of: start) { _ in player?.stop(); playing = false }
            .onChange(of: end) { _ in player?.stop(); playing = false }
            .onDisappear { player?.stop(); for url in temporary { try? FileManager.default.removeItem(at: url) } }
        }
    }
    @MainActor private func prepare(share: Bool) async {
        player?.stop(); playing = false
        guard let url = await controller.prepareClip(start: start, end: end) else { return }
        temporary.append(url)
        if share { shared = SharedFile(url: url); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: url)
            guard next.play() else { throw LectureError.message("無法播放片段。") }
            player = next; playing = true
        } catch { controller.errorMessage = error.localizedDescription }
    }
}

struct SpeakerSettingsView: View {
    @ObservedObject var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("錄後講者分段 · beta") {
                    Text("離線辨識講者 A／B／C，再由你命名。相似聲音、插話及跨長片段可能需要合併或修正；不猜真實姓名。")
                    Button("分析已保存錄音的講者") { Task { await controller.analyzeSpeakers() } }
                        .disabled(!controller.canManageSessions || controller.session?.speakerTurns != nil || controller.session?.parts.isEmpty != false)
                    Text(controller.status).font(.caption)
                    if controller.isBusy { ProgressView() }
                    if controller.session?.speakerTurns != nil { Text("已有分析結果；如需重做，可在錄後重新轉錄的副本再分析，保留這份命名。") }
                }
                ForEach((controller.session?.speakerNames ?? [:]).keys.sorted(), id: \.self) { id in
                    Section {
                        TextField("講者名稱", text: Binding(get: { controller.session?.speakerNames?[id] ?? id }, set: { controller.renameSpeaker(id, name: $0) }))
                            .disabled(!controller.canManageSessions)
                        Menu("合併至其他講者") {
                            ForEach((controller.session?.speakerNames ?? [:]).keys.filter { $0 != id }.sorted(), id: \.self) { target in
                                Button(controller.session?.speakerNames?[target] ?? target) { controller.mergeSpeaker(id, into: target) }
                            }
                        }.disabled(!controller.canManageSessions)
                    }
                }
            }.navigationTitle("講者")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(controller.isBusy) } }
                .interactiveDismissDisabled(controller.isBusy)
        }
    }
}
