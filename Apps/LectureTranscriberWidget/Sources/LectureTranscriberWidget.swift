import WidgetKit
import SwiftUI
import ActivityKit

@available(iOS 16.1, *)
@main
struct LectureTranscriberWidgetBundle: WidgetBundle {
    var body: some Widget {
        LectureTranscriberActivityWidget()
    }
}

@available(iOS 16.1, *)
struct LectureTranscriberActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureActivityAttributes.self) { context in
            // Lock Screen presentation
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(.red)
                        Text(context.attributes.lectureTitle)
                            .font(.caption)
                            .bold()
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused {
                        Text(formatDuration(context.state.elapsedWhenPaused))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.yellow)
                    } else if context.state.isRecording && !context.state.isPaused {
                        Text(timerInterval: context.state.timerReferenceDate...Date.distantFuture, pauseTime: nil, countsDown: false)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.red)
                    } else {
                        Text(formatDuration(context.state.elapsedWhenPaused))
                            .font(.caption2.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        if context.state.captionMode != "chineseOnly" {
                            Text(context.state.latestOriginal.isEmpty ? " " : context.state.latestOriginal)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .frame(minHeight: 32, alignment: .topLeading)
                        }
                        if context.state.captionMode != "originalOnly" {
                            Text(context.state.latestTranslation.isEmpty ? " " : context.state.latestTranslation)
                                .font(.caption2)
                                .bold()
                                .foregroundStyle(Color(red: 1.0, green: 0.86, blue: 0.35))
                                .lineLimit(2)
                                .frame(minHeight: 32, alignment: .topLeading)
                        }
                        if context.state.latestOriginal.isEmpty && context.state.latestTranslation.isEmpty {
                            Text(context.state.isPaused ? "錄音已暫停" : "正在聆聽課堂聲音…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(context.state.isPaused ? .yellow : .red)
            } compactTrailing: {
                if context.state.isPaused {
                    Text(formatDuration(context.state.elapsedWhenPaused))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.yellow)
                } else if context.state.isRecording && !context.state.isPaused {
                    Text(timerInterval: context.state.timerReferenceDate...Date.distantFuture, pauseTime: nil, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.red)
                        .frame(maxWidth: 44)
                } else {
                    Text(formatDuration(context.state.elapsedWhenPaused))
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(context.state.isPaused ? .yellow : .red)
            }
        }
    }
}

@available(iOS 16.1, *)
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<LectureActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                    Text(context.attributes.lectureTitle)
                        .font(.subheadline)
                        .bold()
                        .lineLimit(1)
                }
                Spacer()
                if context.state.isPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill")
                            .font(.caption2)
                        Text(formatDuration(context.state.elapsedWhenPaused))
                    }
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.yellow)
                } else if context.state.isRecording && !context.state.isPaused {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                        Text(timerInterval: context.state.timerReferenceDate...Date.distantFuture, pauseTime: nil, countsDown: false)
                    }
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.primary)
                } else {
                    Text(formatDuration(context.state.elapsedWhenPaused))
                        .font(.caption.monospacedDigit().bold())
                }
            }

            // Body: Subtitles
            VStack(alignment: .leading, spacing: 3) {
                if context.state.captionMode != "chineseOnly" {
                    Text(context.state.latestOriginal.isEmpty ? "等待語音…" : context.state.latestOriginal)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(minHeight: 38, alignment: .topLeading)
                }
                if context.state.captionMode != "originalOnly" {
                    Text(context.state.latestTranslation.isEmpty ? " " : context.state.latestTranslation)
                        .font(.footnote)
                        .bold()
                        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.20))
                        .lineLimit(2)
                        .frame(minHeight: 38, alignment: .topLeading)
                }
            }
            .padding(.vertical, 2)

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(context.state.isPaused ? .yellow : .green)
                        .frame(width: 5, height: 5)
                    Text(context.state.isPaused ? "已暫停" : "錄音中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.recognitionEngineName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .widgetURL(URL(string: "lecturetranscriber://lecture/\(context.attributes.lectureID)/transcript"))
        .padding(14)
        .background(Color(uiColor: .systemBackground))
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 {
        return String(format: "%02d:%02d:%02d", h, m, sec)
    } else {
        return String(format: "%02d:%02d", m, sec)
    }
}
