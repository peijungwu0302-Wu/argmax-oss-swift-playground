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
                Text(L10n.tr("音訊合計 ", "Total Audio ") + controller.audioSize(lecture))
                Text(L10n.tr("每次停止／繼續會保存成不同片段，可分別播放及分享。原始 PCM 會轉成通用 WAV；AAC 直接分享 M4A。", "Each stop/resume saves as a separate segment. Original PCM converts to universal WAV; AAC shares M4A.")).font(.caption)
            }
            ForEach(Array(lecture.parts.enumerated()), id: \.element.id) { index, part in
                Section(L10n.tr("片段 \(index + 1) · \(TranscriptExport.clock(part.offset))", "Segment \(index + 1) · \(TranscriptExport.clock(part.offset))")) {
                    Text(L10n.tr("長度 \(TranscriptExport.clock(Double(part.sampleCount) / 16000)) · \(part.fileName.pathExtensionLabel)", "Duration \(TranscriptExport.clock(Double(part.sampleCount) / 16000)) · \(part.fileName.pathExtensionLabel)"))
                    if let url = controller.audioURL(lecture, part) {
                        Text(ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file)).foregroundStyle(.secondary)
                        HStack {
                            Button(playing == part.id && player?.isPlaying == true ? L10n.tr("暫停", "Pause") : L10n.tr("播放", "Play")) {
                                if playing == part.id, let player, player.isPlaying { player.pause(); playing = nil }
                                else { Task { await prepare(part, url: url, share: false) } }
                            }
                            Spacer()
                            Button(L10n.tr("分享音訊", "Share Audio")) { Task { await prepare(part, url: url, share: true) } }
                        }.buttonStyle(.borderless).disabled(preparing)
                    }
                }
            }
            if preparing { ProgressView(L10n.tr("正在準備音訊…", "Preparing audio…")) }
        }.navigationTitle(L10n.tr("錄音檔案", "Audio Files"))
            .sheet(item: $shared) { ShareSheet(url: $0.url) }
            .alert(L10n.tr("音訊檔案", "Audio Files"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.tr("知道了", "OK")) { problem = nil }
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
                try AudioSessionCoordinator.shared.activatePlayback()
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
