import Foundation
import Combine

enum LiveActivityPhase: String, Codable, Equatable {
    case recording, paused, stopping, stopped
}

struct LiveActivityTimerState: Equatable {
    private(set) var phase: LiveActivityPhase = .recording
    private(set) var accumulated: TimeInterval = 0
    private var runningSince: Date?

    init(startedAt: Date) { runningSince = startedAt }

    var rendersRunningTimer: Bool { phase == .recording && runningSince != nil }

    mutating func pause(at now: Date = Date()) {
        guard phase == .recording else { return }
        accumulate(until: now)
        phase = .paused
    }

    mutating func resume(at now: Date = Date()) {
        guard phase == .paused else { return }
        runningSince = now
        phase = .recording
    }

    mutating func beginStopping(at now: Date = Date()) {
        if phase == .recording { accumulate(until: now) }
        phase = .stopping
    }

    mutating func stop(at now: Date = Date()) {
        beginStopping(at: now)
        phase = .stopped
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard rendersRunningTimer, let runningSince else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(runningSince))
    }

    var timerReferenceDate: Date { Date().addingTimeInterval(-elapsed()) }

    private mutating func accumulate(until now: Date) {
        if let runningSince { accumulated += max(0, now.timeIntervalSince(runningSince)) }
        runningSince = nil
    }
}

enum LiveActivityRefreshPreset: String, CaseIterable, Identifiable, Codable {
    case fast, balanced, saver
    var id: String { rawValue }
    var interval: TimeInterval {
        switch self { case .fast: return 0.10; case .balanced: return 0.25; case .saver: return 0.50 }
    }
    var title: String {
        switch self {
        case .fast: return L10n.tr("快速（0.10 秒）", "Fast (0.10 s)")
        case .balanced: return L10n.tr("平衡（0.25 秒·預設）", "Balanced (0.25 s, Default)")
        case .saver: return L10n.tr("省電（0.50 秒）", "Saver (0.50 s)")
        }
    }
}

struct LatestCaptionCoalescer {
    let interval: TimeInterval
    private var lastPublishedAt: Date?
    private var pending: String?
    private var lastPublished = ""

    init(interval: TimeInterval) { self.interval = max(0.10, interval) }

    mutating func offer(_ value: String, at now: Date = Date()) -> String? {
        guard value != lastPublished, value != pending else { return nil }
        if lastPublishedAt == nil || now.timeIntervalSince(lastPublishedAt!) >= interval {
            lastPublishedAt = now; lastPublished = value; pending = nil
            return value
        }
        pending = value
        return nil
    }

    mutating func flush(at now: Date = Date()) -> String? {
        guard let pending, lastPublishedAt == nil || now.timeIntervalSince(lastPublishedAt!) >= interval else { return nil }
        self.pending = nil; lastPublished = pending; lastPublishedAt = now
        return pending
    }
}

@MainActor
final class DisplaySettings: ObservableObject {
    static let shared = DisplaySettings()
    private let defaults: UserDefaults
    @Published var appOriginalScale: Double { didSet { persistScale(appOriginalScale, key: "displayAppOriginalScale") } }
    @Published var appTranslationScale: Double { didSet { persistScale(appTranslationScale, key: "displayAppTranslationScale") } }
    @Published var pipOriginalScale: Double { didSet { persistScale(pipOriginalScale, key: "displayPiPOriginalScale") } }
    @Published var pipTranslationScale: Double { didSet { persistScale(pipTranslationScale, key: "displayPiPTranslationScale") } }
    @Published var historyScale: Double { didSet { persistScale(historyScale, key: "displayHistoryScale") } }
    @Published var showAppCaptions: Bool { didSet { defaults.set(showAppCaptions, forKey: "displayShowAppCaptions") } }
    @Published var showPiPCaptions: Bool { didSet { defaults.set(showPiPCaptions, forKey: "displayShowPiPCaptions") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appOriginalScale = Self.read(defaults, "displayAppOriginalScale")
        appTranslationScale = Self.read(defaults, "displayAppTranslationScale")
        pipOriginalScale = Self.read(defaults, "displayPiPOriginalScale")
        pipTranslationScale = Self.read(defaults, "displayPiPTranslationScale")
        historyScale = Self.read(defaults, "displayHistoryScale")
        showAppCaptions = defaults.object(forKey: "displayShowAppCaptions") as? Bool ?? true
        showPiPCaptions = defaults.object(forKey: "displayShowPiPCaptions") as? Bool ?? true
    }

    func resetAll() {
        appOriginalScale = 1; appTranslationScale = 1
        pipOriginalScale = 1; pipTranslationScale = 1; historyScale = 1
        showAppCaptions = true; showPiPCaptions = true
    }

    private static func read(_ defaults: UserDefaults, _ key: String) -> Double {
        min(3, max(0.3, defaults.object(forKey: key) as? Double ?? 1))
    }
    private func persistScale(_ value: Double, key: String) {
        let clamped = min(3, max(0.3, value))
        defaults.set(clamped, forKey: key)
    }

    static func maxLines(for scale: Double) -> Int {
        if scale >= 2.4 { return 1 }
        if scale >= 1.7 { return 2 }
        if scale >= 0.9 { return 3 }
        return 5
    }
}

enum DeviceAudioSavePreference: String, CaseIterable, Identifiable, Codable {
    case askEveryTime, alwaysSave, alwaysDiscard
    static let defaultValue = DeviceAudioSavePreference.askEveryTime
    var id: String { rawValue }
    var requiresDecision: Bool { self == .askEveryTime }
}

struct ASRSwitchBoundary: Equatable, Codable {
    let engine: String
    let sampleIndex: Int
    let timestamp: TimeInterval
    let totalBuffers: Int
    func switching(to engine: String, atSample sampleIndex: Int, timestamp: TimeInterval) -> ASRSwitchBoundary {
        ASRSwitchBoundary(engine: engine, sampleIndex: max(self.sampleIndex, sampleIndex),
                          timestamp: max(self.timestamp, timestamp), totalBuffers: totalBuffers)
    }
}

struct TranslationRoute: Codable, Hashable, Identifiable {
    var source: String
    var target: String
    var id: String { "\(source)->\(target)" }
    static let englishTraditionalChinese = TranslationRoute(source: "en", target: "zh-Hant")
    static let japaneseTraditionalChinese = TranslationRoute(source: "ja", target: "zh-Hant")
}

enum TranslationQualityStrategy: String, CaseIterable, Identifiable, Codable {
    case automatic, lowLatency, highFidelity
    var id: String { rawValue }
}

enum TranslationCoordinatorState: String, Codable { case idle, preparing, ready, translating, recovering, failed }

struct PendingTranslation: Identifiable, Equatable {
    let line: TranscriptLine
    let route: TranslationRoute
    var id: UUID { line.id }
}

struct TranslationRecoveryQueue {
    private(set) var pending: [PendingTranslation] = []
    mutating func enqueue(_ line: TranscriptLine, route: TranslationRoute) {
        guard !pending.contains(where: { $0.line.id == line.id && $0.route == route }) else { return }
        pending.append(PendingTranslation(line: line, route: route))
    }
    mutating func markCompleted(lineID: UUID) { pending.removeAll { $0.line.id == lineID } }
    mutating func removeCompleted(_ lineIDs: Set<UUID>) {
        guard !lineIDs.isEmpty else { return }
        pending.removeAll { lineIDs.contains($0.line.id) }
    }
}
