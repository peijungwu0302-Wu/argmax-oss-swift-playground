import SwiftUI
import Translation

// MARK: - Translation Provider Protocol & Placeholders

public protocol TranslationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

public struct FeatureFlags {
    public static let googleCloudTranslation = false
    public static let microsoftTranslation = false
}

public final class GoogleCloudTranslationProvider: TranslationProvider {
    public let id = "google"
    public var displayName: String { L10n.tr("Google 雲端翻譯（未啟用）", "Google Cloud Translation (Disabled)") }
    public var isAvailable: Bool { FeatureFlags.googleCloudTranslation }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard FeatureFlags.googleCloudTranslation else {
            throw LectureError.message(L10n.tr("Google 雲端翻譯未啟用（本版本不使用任何付費 API 金鑰）。", "Google Cloud Translation is disabled."))
        }
        return text
    }
}

public final class MicrosoftAzureTranslationProvider: TranslationProvider {
    public let id = "microsoft"
    public var displayName: String { L10n.tr("Microsoft Azure 翻譯（未啟用）", "Microsoft Azure Translation (Disabled)") }
    public var isAvailable: Bool { FeatureFlags.microsoftTranslation }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard FeatureFlags.microsoftTranslation else {
            throw LectureError.message(L10n.tr("Microsoft 翻譯未啟用（本版本不使用任何付費 API 金鑰）。", "Microsoft Azure Translation is disabled."))
        }
        return text
    }
}

// MARK: - Speed Presets

public enum TranslationSpeedPreset: String, CaseIterable, Identifiable, Codable {
    case ultraFast = "ultraFast"   // 0.25s
    case fast = "fast"             // 0.40s (default)
    case balanced = "balanced"     // 0.70s
    case stable = "stable"         // 1.00s
    case custom = "custom"         // Custom slider 0.20s - 2.00s

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraFast: return L10n.tr("極快 (0.25s)", "Ultra Fast (0.25s)")
        case .fast: return L10n.tr("快速 (0.40s · 預設)", "Fast (0.40s · Default)")
        case .balanced: return L10n.tr("平衡 (0.70s)", "Balanced (0.70s)")
        case .stable: return L10n.tr("穩定 (1.00s)", "Stable (1.00s)")
        case .custom: return L10n.tr("自訂區間", "Custom Interval")
        }
    }

    public var defaultInterval: TimeInterval {
        switch self {
        case .ultraFast: return 0.25
        case .fast: return 0.40
        case .balanced: return 0.70
        case .stable: return 1.00
        case .custom: return 0.40
        }
    }
}

// MARK: - SwiftUI Modifier

struct LiveTranslationModifier: ViewModifier {
    @ObservedObject var controller: LectureController
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(TranslationWorker(controller: controller))
        } else {
            content.onChange(of: controller.translationEnabled) { enabled in
                if enabled { controller.translationStatus = L10n.tr("中文翻譯需要 iPadOS 18 或更新版本", "Chinese translation requires iOS/iPadOS 18+") }
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
                if enabled {
                    configure()
                } else {
                    configuration = nil
                    controller.translationStatus = L10n.tr("翻譯已關閉；已完成的翻譯仍保留", "Translation off; completed lines kept")
                }
            }
            .onChange(of: controller.translationSource) { _ in configure() }
            .onChange(of: controller.translationGeneration) { _ in configure() }
            .translationTask(configuration) { @MainActor translator in
                guard controller.translationEnabled else { return }
                do {
                    controller.translationStatus = L10n.tr("正在準備翻譯語言；首次需要下載語言資源", "Preparing translation language model…")
                    try await translator.prepareTranslation()
                    var previousDraft: DraftTranslationKey?
                    var lastDraftAt = Date.distantPast
                    var draftWasLast = false
                    var retryAfter: [UUID: Date] = [:]

                    while !Task.isCancelled && controller.translationEnabled {
                        guard let lecture = controller.session, !controller.isSummarizing, controller.canProcessLiveAudio else {
                            try await Task.sleep(nanoseconds: 200_000_000)
                            continue
                        }

                        let interval = controller.translationInterval
                        let key = controller.draftTranslationKey
                        let translateDraft = key != nil && key != previousDraft
                            && Date().timeIntervalSince(lastDraftAt) >= interval
                            && (!draftWasLast || lecture.lines.first { lecture.translation(for: $0) == nil } == nil)

                        let pending = lecture.lines.first {
                            lecture.translation(for: $0) == nil && (retryAfter[$0.id] ?? .distantPast) <= Date()
                        }

                        do {
                            // LIVE LANE PRIORITY
                            if translateDraft, let key {
                                lastDraftAt = Date(); draftWasLast = true
                                let text = try await translate(key.source, with: translator)
                                try Task.checkCancellation()
                                guard controller.translationEnabled else { return }
                                previousDraft = key
                                if let current = controller.draftTranslationKey, key.accepts(current) {
                                    controller.translationDraftKey = key
                                    controller.translationDraftSource = key.source
                                    controller.translatedDraft = text
                                }
                            }
                            // BACKLOG LANE
                            else if let line = pending {
                                draftWasLast = false
                                controller.translationStatus = L10n.tr("正在翻譯 \(TranscriptExport.clock(line.start)) 的段落…", "Translating segment at \(TranscriptExport.clock(line.start))…")
                                let text = try await translate(line.text, with: translator)
                                try Task.checkCancellation()
                                guard controller.translationEnabled else { return }
                                controller.saveTranslation(sessionID: lecture.id, line: line, text: text)
                                retryAfter.removeValue(forKey: line.id)
                            }
                            // IDLE LANE
                            else {
                                controller.translationStatus = retryAfter.isEmpty
                                    ? L10n.tr("裝置端翻譯已就緒", "On-device translation ready")
                                    : L10n.tr("部分段落等待重試；新字幕仍持續翻譯", "Some segments retrying; live translation active")
                                try await Task.sleep(nanoseconds: 150_000_000)
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            guard controller.translationEnabled else { return }
                            if !translateDraft, let pending {
                                retryAfter[pending.id] = Date().addingTimeInterval(5)
                            }
                            controller.translationStatus = L10n.tr("翻譯暫時失敗，稍後自動重試：\(error.localizedDescription)", "Translation failed temporarily: \(error.localizedDescription)")
                            try await Task.sleep(nanoseconds: 600_000_000)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    guard controller.translationEnabled else { return }
                    controller.translationStatus = L10n.tr("翻譯語言尚未就緒：\(error.localizedDescription)。可按「重試翻譯」。", "Translation not ready: \(error.localizedDescription)")
                }
            }
    }

    private func configure() {
        guard controller.translationEnabled else {
            configuration = nil
            return
        }
        configuration = .init(
            source: Locale.Language(identifier: controller.translationSource),
            target: Locale.Language(identifier: "zh-Hant")
        )
    }

    @MainActor
    private func translate(_ text: String, with translator: TranslationSession) async throws -> String {
        if controller.translationSource == "ja" {
            return try await translator.translate(text).targetText
        }
        var result = text
        for range in TranslationText.englishRanges(text).reversed() {
            let original = (text as NSString).substring(with: range)
            let response = try await translator.translate(original)
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: response.targetText)
            }
        }
        return result
    }
}
