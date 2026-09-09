import SwiftUI
import AVFoundation

struct AudioLibraryView: View {
    @ObservedObject var controller: LectureController
    let lecture: LectureSession
    @State private var player: AVAudioPlayer?
    @State private var playing: UUID?
    @State private var preparing = false
    @State private var shared: SharedFile?
    @State private var problem: String?
    var body: some View {
        List {
            Section {
                Text(lecture.title).font(.headline)
                Text("音訊合計 " + controller.audioSize(lecture))
                Text("每次停止／繼續會保存成不同片段，可分別播放及分享。原始 PCM 會轉成通用 WAV；AAC 直接分享 M4A。").font(.caption)
            }
            ForEach(Array(lecture.parts.enumerated()), id: \.element.id) { index, part in
                Section("片段 \(index + 1) · \(TranscriptExport.clock(part.offset))") {
                    Text("長度 \(TranscriptExport.clock(Double(part.sampleCount) / 16000)) · \(part.fileName.pathExtensionLabel)")
                    if let url = controller.audioURL(lecture, part) {
                        Text(ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file)).foregroundStyle(.secondary)
                        HStack {
                            Button(playing == part.id && player?.isPlaying == true ? "暫停" : "播放") {
                                if playing == part.id, let player, player.isPlaying { player.pause(); playing = nil }
                                else { Task { await prepare(part, url: url, share: false) } }
                            }
                            Spacer()
                            Button("分享音訊") { Task { await prepare(part, url: url, share: true) } }
                        }.buttonStyle(.borderless).disabled(preparing)
                    }
                }
            }
            if preparing { ProgressView("正在準備音訊…") }
        }.navigationTitle("錄音檔案")
            .sheet(item: $shared) { ShareSheet(url: $0.url) }
            .alert("音訊檔案", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("知道了") { problem = nil }
            } message: { Text(problem ?? "") }
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if playing != nil && player?.isPlaying != true { playing = nil }
            }
            .onDisappear { player?.stop(); player = nil; playing = nil }
    }
    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    @MainActor private func prepare(_ part: AudioPart, url: URL, share: Bool) async {
        preparing = true; defer { preparing = false }
        do {
            player?.stop(); playing = nil
            let playable = try await Task.detached(priority: .userInitiated) { try StoredAudio.playable(url, samples: part.sampleCount) }.value
            if share { shared = SharedFile(url: playable) }
            else {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let next = try AVAudioPlayer(contentsOf: playable)
                guard next.play() else { throw LectureError.message("無法播放這段音訊。") }
                player = next; playing = part.id
            }
        } catch { problem = error.localizedDescription }
    }
}
private extension String {
    var pathExtensionLabel: String { URL(fileURLWithPath: self).pathExtension.uppercased() }
}
