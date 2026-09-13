import SwiftUI

struct FullTranscriptView: View {
    @ObservedObject var controller: LectureController
    @EnvironmentObject private var navigation: AppNavigationState
    let lectureID: UUID
    @State private var followLive = true

    private var lecture: LectureSession? {
        if controller.session?.id == lectureID { return controller.session }
        return controller.history.first { $0.id == lectureID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { navigation.route = .home } label: {
                    Label(L10n.tr("返回", "Back"), systemImage: "chevron.left")
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(L10n.tr("完整逐字稿", "Full Transcript")).font(.headline)
                    Text(TranscriptExport.clock(lecture?.duration ?? 0)).font(.caption.monospacedDigit())
                }
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding()

            Divider()
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(lecture?.lines ?? []) { line in
                                TranscriptLineRow(line: line, translation: lecture?.translation(for: line)?.text)
                            }
                            if controller.session?.id == lectureID, !controller.displayedDraft.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.tr("目前草稿", "Current Draft"))
                                        .font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(controller.displayedDraft).textSelection(.enabled)
                                    if !controller.validTranslatedDraft.isEmpty {
                                        Text(controller.validTranslatedDraft).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }
                            Color.clear.frame(height: 1).id("live-bottom")
                        }
                        .padding()
                    }
                    .simultaneousGesture(DragGesture().onChanged { value in
                        if value.translation.height > 8 { followLive = false }
                    })
                    .onChange(of: lecture?.lines.count) { _ in
                        if followLive { withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) } }
                    }
                    .onChange(of: controller.displayedDraft) { _ in
                        if followLive { proxy.scrollTo("live-bottom", anchor: .bottom) }
                    }

                    if !followLive {
                        Button {
                            withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                            followLive = true
                        } label: {
                            Label(L10n.tr("回到即時", "Return to Live"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                }
            }
        }
        .background(Color(red: 0.97, green: 0.95, blue: 0.90))
        .onAppear {
            if controller.session?.id != lectureID, !controller.isRecording,
               let saved = controller.history.first(where: { $0.id == lectureID }) {
                controller.open(saved)
            }
        }
    }
}

struct TranscriptLineRow: View {
    let line: TranscriptLine
    let translation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TranscriptExport.clock(line.start))
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(Color(red: 0.59, green: 0.40, blue: 0.08))
            Text(line.text).textSelection(.enabled)
            if let translation, !translation.isEmpty {
                Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}
