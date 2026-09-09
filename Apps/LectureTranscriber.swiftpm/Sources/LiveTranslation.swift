import SwiftUI
import Translation

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
            .onAppear { configure() }
            .onChange(of: controller.translationEnabled) { enabled in
                controller.restartTranslation()
                if !enabled { controller.translationStatus = "翻譯已關閉；已完成的翻譯仍保留" }
            }
            .onChange(of: controller.translationGeneration) { _ in configure() }
            .translationTask(configuration) { @MainActor translator in
                guard controller.translationEnabled else { return }
                let generation = controller.translationGeneration
                do {
                    controller.translationStatus = "正在準備英語／中文翻譯；首次需要下載語言"
                    try await translator.prepareTranslation()
                    var previousDraft: DraftTranslationKey?
                    var lastDraftAt = Date.distantPast
                    var draftWasLast = false
                    var retryAfter: [UUID: Date] = [:]
                    while !Task.isCancelled && controller.translationEnabled && generation == controller.translationGeneration {
                        guard let lecture = controller.session, !controller.isSummarizing else {
                            try await Task.sleep(nanoseconds: 300_000_000)
                            continue
                        }
                        let pending = lecture.lines.first {
                            lecture.translation(for: $0) == nil && (retryAfter[$0.id] ?? .distantPast) <= Date()
                        }
                        let key = controller.draftTranslationKey
                        let translateDraft = key != nil && key != previousDraft
                            && Date().timeIntervalSince(lastDraftAt) >= 0.7 && (!draftWasLast || pending == nil)
                        do {
                            if translateDraft, let key {
                                lastDraftAt = Date(); draftWasLast = true
                                let text = try await translate(key.source, with: translator)
                                try Task.checkCancellation()
                                guard generation == controller.translationGeneration, controller.translationEnabled else { return }
                                previousDraft = key // Failed requests remain eligible for retry.
                                if let current = controller.draftTranslationKey, key.accepts(current) {
                                    controller.translationDraftKey = key
                                    controller.translationDraftSource = key.source
                                    controller.translatedDraft = text
                                }
                            } else if let line = pending {
                                draftWasLast = false
                                controller.translationStatus = "正在翻譯 \(TranscriptExport.clock(line.start)) 的段落…"
                                let text = try await translate(line.text, with: translator)
                                try Task.checkCancellation()
                                guard generation == controller.translationGeneration, controller.translationEnabled else { return }
                                controller.saveTranslation(sessionID: lecture.id, line: line, text: text)
                                retryAfter.removeValue(forKey: line.id)
                            } else {
                                controller.translationStatus = retryAfter.isEmpty
                                    ? "裝置端翻譯已就緒 · 中文原文保留，英語翻成中文"
                                    : "部分段落等待重試；新字幕仍持續翻譯"
                                try await Task.sleep(nanoseconds: 250_000_000)
                            }
                        } catch is CancellationError { return }
                        catch {
                            guard generation == controller.translationGeneration, controller.translationEnabled else { return }
                            // One failed sentence cannot kill the worker or block every later sentence.
                            if !translateDraft, let pending { retryAfter[pending.id] = Date().addingTimeInterval(5) }
                            controller.translationStatus = "翻譯暫時失敗，稍後自動重試：\(error.localizedDescription)"
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                } catch is CancellationError { }
                catch {
                    guard generation == controller.translationGeneration, controller.translationEnabled else { return }
                    controller.translationStatus = "翻譯語言尚未就緒：\(error.localizedDescription)。可按「重試翻譯」。"
                }
            }
    }
    private func configure() {
        if !controller.translationEnabled { configuration = nil }
        else if configuration == nil {
            configuration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hant"))
        } else { configuration?.invalidate() }
    }
    @MainActor
    private func translate(_ text: String, with translator: TranslationSession) async throws -> String {
        var result = text
        for range in TranslationText.englishRanges(text).reversed() {
            let original = (text as NSString).substring(with: range)
            let response = try await translator.translate(original)
            if let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: response.targetText) }
        }
        return result
    }
}
