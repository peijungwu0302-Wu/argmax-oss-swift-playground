import SwiftUI
import Translation

// The TranslationSession stays inside the lifetime of its SwiftUI task.
struct LiveTranslationModifier: ViewModifier {
    @ObservedObject var controller: LectureController
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(TranslationWorker(controller: controller))
        } else {
            content.onChange(of: controller.translationEnabled) { enabled in
                if enabled { controller.translationStatus = "中文翻譯需要 iPadOS 18 或更新版本" }
            }
        }
    }
}

@available(iOS 18.0, *)
private struct TranslationWorker: ViewModifier {
    @ObservedObject var controller: LectureController
    @State private var configuration: TranslationSession.Configuration?
    func body(content: Content) -> some View {
        content
            .onChange(of: controller.translationEnabled) { enabled in
                controller.translatedDraft = ""
                configuration = enabled ? .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hant")) : nil
                if !enabled { controller.translationStatus = "翻譯已關閉；已完成的翻譯仍保留" }
            }
            .translationTask(configuration) { @MainActor translator in
                guard controller.translationEnabled else { return }
                do {
                    controller.translationStatus = "正在準備英語／中文翻譯；首次需要下載語言"
                    try await translator.prepareTranslation()
                    var previousDraft = ""
                    var previousSession: UUID?
                    var lastDraftAt = Date.distantPast
                    while !Task.isCancelled && controller.translationEnabled {
                        guard let lecture = controller.session else {
                            controller.translationStatus = "翻譯已就緒 · 開始錄音後會逐段顯示"
                            try await Task.sleep(nanoseconds: 500_000_000)
                            continue
                        }
                        if previousSession != lecture.id {
                            previousSession = lecture.id; previousDraft = ""; controller.translatedDraft = ""
                        }
                        if controller.isSummarizing {
                            try await Task.sleep(nanoseconds: 500_000_000)
                            continue
                        }
                        if let line = lecture.lines.first(where: { lecture.translation(for: $0) == nil }) {
                            controller.translationStatus = "正在翻譯 \(TranscriptExport.clock(line.start)) 的段落…"
                            let text = try await translate(line.text, with: translator)
                            try Task.checkCancellation()
                            guard controller.translationEnabled else { return }
                            controller.saveTranslation(sessionID: lecture.id, line: line, text: text)
                            controller.translatedDraft = ""
                            continue
                        }
                        let draft = controller.displayedDraft
                        if !draft.isEmpty && draft != previousDraft && Date().timeIntervalSince(lastDraftAt) >= 3 {
                            previousDraft = draft; lastDraftAt = Date()
                            let result = try await translate(draft, with: translator)
                            try Task.checkCancellation()
                            if controller.translationEnabled && controller.session?.id == lecture.id && controller.displayedDraft == draft {
                                controller.translatedDraft = result
                            }
                        } else if draft.isEmpty { controller.translatedDraft = "" }
                        controller.translationStatus = "裝置端翻譯已就緒 · 中文原文保留，英語翻成中文"
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                } catch is CancellationError {
                    // Switching off or leaving the screen cancels safely.
                } catch {
                    guard controller.translationEnabled else { return }
                    controller.translationStatus = "翻譯暫停：\(error.localizedDescription)。請關閉再開啟翻譯重試；錄音不受影響。"
                }
            }
    }
    @MainActor
    private func translate(_ text: String, with translator: TranslationSession) async throws -> String {
        // Separate English runs so Chinese-led mixed speech is never sent as English.
        // Chinese punctuation and original text are preserved; short names may need correction.
        var result = text
        for range in TranslationText.englishRanges(text).reversed() {
            let original = (text as NSString).substring(with: range)
            let response = try await translator.translate(original)
            if let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: response.targetText) }
        }
        return result
    }
}
