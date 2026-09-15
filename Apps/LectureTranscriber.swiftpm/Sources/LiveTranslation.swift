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
    public static let googleMLKitOfflineTranslation = false
    public static let microsoftTranslation = false
}

@MainActor
final class TranslationCoordinator: ObservableObject {
    static let shared = TranslationCoordinator()
    @Published private(set) var state: TranslationCoordinatorState = .idle
    private(set) var queue = TranslationRecoveryQueue()
    private var attempts = 0
    private var recoveryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastProgress = Date()

    func setState(_ state: TranslationCoordinatorState) { self.state = state }
    func synchronize(_ lines: [TranscriptLine], route: TranslationRoute, translatedIDs: Set<UUID>) {
        for line in lines where !translatedIDs.contains(line.id) { queue.enqueue(line, route: route) }
        armWatchdogIfNeeded()
    }
    func nextPending() -> PendingTranslation? { queue.pending.first }
    func completed(_ id: UUID) {
        queue.markCompleted(lineID: id); attempts = 0; lastProgress = Date(); state = .ready
        if queue.pending.isEmpty { watchdogTask?.cancel(); watchdogTask = nil }
    }
    func recover(controller: LectureController, error: Error) {
        guard !queue.pending.isEmpty else { state = .failed; return }
        attempts += 1; state = .recovering
        let delay = min(16.0, pow(2.0, Double(max(0, attempts - 1))))
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let controller, controller.translationEnabled else { return }
            controller.translationStatus = L10n.tr("正在自動重建翻譯階段…", "Recreating translation session…")
            controller.restartTranslation()
            self.lastProgress = Date()
        }
    }
    private func armWatchdogIfNeeded() {
        guard !queue.pending.isEmpty, watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !self.queue.pending.isEmpty else { return }
                if Date().timeIntervalSince(self.lastProgress) > 15, self.state != .translating { self.state = .recovering }
            }
        }
    }
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
    @ObservedObject private var coordinator = TranslationCoordinator.shared
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
                    coordinator.setState(.preparing)
                    controller.translationStatus = L10n.tr("正在準備翻譯語言；首次需要下載語言資源", "Preparing translation language model…")
                    try await translator.prepareTranslation()
                    coordinator.setState(.ready)
                    var previousDraft: DraftTranslationKey?
                    var lastDraftAt = Date.distantPast
                    var lastDraftSource = ""
                    var lastDraftSourceChangeAt = Date.distantPast
                    var draftWasLast = false
                    var retryAfter: [UUID: Date] = [:]

                    while !Task.isCancelled && controller.translationEnabled {
                        guard let lecture = controller.session, !controller.isSummarizing, controller.canProcessLiveAudio else {
                            try await Task.sleep(nanoseconds: 200_000_000)
                            continue
                        }

                        let now = Date()
                        let interval = controller.translationInterval
                        let key = controller.draftTranslationKey
                        if let key, key.source != lastDraftSource {
                            lastDraftSource = key.source
                            lastDraftSourceChangeAt = now
                        }

                        let isMeaningful = key.map { SegmentMerger.isMeaningfulDraft($0.source) } ?? false
                        let pauseThresholdReached = now.timeIntervalSince(lastDraftSourceChangeAt) >= 0.5
                        let isDraftStableEnough = isMeaningful || pauseThresholdReached

                        let translateDraft = controller.translationStrategy != .highFidelity && key != nil && key != previousDraft
                            && isDraftStableEnough
                            && now.timeIntervalSince(lastDraftAt) >= interval
                            && (!draftWasLast || lecture.lines.first { lecture.translation(for: $0) == nil } == nil)

                        let translatedIDs = Set((lecture.translations ?? []).map(\.id))
                        coordinator.synchronize(lecture.lines, route: TranslationRoute(source: controller.translationSource, target: controller.translationTarget), translatedIDs: translatedIDs)
                        let queued = coordinator.nextPending()
                        let pending = queued.flatMap { (retryAfter[$0.line.id] ?? .distantPast) <= now ? $0.line : nil }

                        do {
                            // LIVE LANE PRIORITY
                            if translateDraft, let key {
                                coordinator.setState(.translating)
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
                                coordinator.setState(.translating)
                                draftWasLast = false
                                // If this line is the last confirmed line, ends with a dangling clause, and recording is ongoing,
                                // give a short grace period (1.0s) for the next segment to arrive so we can merge them before translating.
                                let isLastLine = lecture.lines.last?.id == line.id
                                if isLastLine, controller.isRecording, SegmentMerger.isDangling(line.text), retryAfter[line.id] == nil {
                                    retryAfter[line.id] = now.addingTimeInterval(1.0)
                                    try await Task.sleep(nanoseconds: 150_000_000)
                                    continue
                                }

                                var textToTranslate = line.text
                                var mergedNextLine: TranscriptLine? = nil
                                if let lineIdx = lecture.lines.firstIndex(where: { $0.id == line.id }),
                                   lineIdx + 1 < lecture.lines.count {
                                    let nextLine = lecture.lines[lineIdx + 1]
                                    if SegmentMerger.shouldMerge(previous: line.text, next: nextLine.text) {
                                        textToTranslate = SegmentMerger.mergeText(previous: line.text, next: nextLine.text)
                                        mergedNextLine = nextLine
                                    }
                                }

                                controller.translationStatus = L10n.tr("正在翻譯 \(TranscriptExport.clock(line.start)) 的段落…", "Translating segment at \(TranscriptExport.clock(line.start))…")
                                let text = try await translate(textToTranslate, with: translator)
                                try Task.checkCancellation()
                                guard controller.translationEnabled else { return }
                                controller.saveTranslation(sessionID: lecture.id, line: line, text: text)
                                coordinator.completed(line.id)
                                if let merged = mergedNextLine {
                                    controller.saveTranslation(sessionID: lecture.id, line: merged, text: text)
                                    retryAfter.removeValue(forKey: merged.id)
                                }
                                retryAfter.removeValue(forKey: line.id)
                            }
                            // IDLE LANE
                            else {
                                coordinator.setState(.ready)
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
                            coordinator.recover(controller: controller, error: error)
                            try await Task.sleep(nanoseconds: 600_000_000)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    guard controller.translationEnabled else { return }
                    controller.translationStatus = L10n.tr("翻譯語言尚未就緒：\(error.localizedDescription)。可按「重試翻譯」。", "Translation not ready: \(error.localizedDescription)")
                    coordinator.recover(controller: controller, error: error)
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
            target: Locale.Language(identifier: controller.translationTarget)
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
