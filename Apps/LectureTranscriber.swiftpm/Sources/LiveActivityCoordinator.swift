import Foundation
import SwiftUI

#if canImport(ActivityKit)
import ActivityKit
#endif

struct LiveActivityClock: Equatable {
    private(set) var timerReferenceDate: Date
    private(set) var elapsedWhenPaused: TimeInterval
    private var runningSince: Date?

    init(startedAt: Date, elapsed: TimeInterval = 0, running: Bool = true) {
        elapsedWhenPaused = max(0, elapsed)
        timerReferenceDate = startedAt.addingTimeInterval(-elapsedWhenPaused)
        runningSince = running ? startedAt : nil
    }

    mutating func pause(at now: Date = Date()) {
        if let runningSince { elapsedWhenPaused += max(0, now.timeIntervalSince(runningSince)) }
        runningSince = nil
    }

    mutating func resume(at now: Date = Date()) {
        guard runningSince == nil else { return }
        runningSince = now
        timerReferenceDate = now.addingTimeInterval(-elapsedWhenPaused)
    }

    var isPaused: Bool { runningSince == nil }
}

enum LiveActivityCaptionKind: Equatable { case meaningfulPartial, finalOriginal, finalTranslation }
enum LiveActivityUpdateDecision: Equatable { case send, coalesce, ignore }

struct LiveActivityUpdatePolicy {
    let partialInterval: TimeInterval
    private(set) var lastSentAt: Date?
    private var lastSeenOriginal = ""
    private var lastSeenTranslation = ""
    private var lastSeenRevision = -1

    init(partialInterval: TimeInterval = 1) { self.partialInterval = max(1, partialInterval) }

    mutating func accept(kind: LiveActivityCaptionKind, revision: Int, original: String,
                         translation: String, at now: Date = Date()) -> LiveActivityUpdateDecision {
        guard revision >= lastSeenRevision else { return .ignore }
        guard original != lastSeenOriginal || translation != lastSeenTranslation || revision != lastSeenRevision else { return .ignore }
        lastSeenOriginal = original
        lastSeenTranslation = translation
        lastSeenRevision = revision
        if kind != .meaningfulPartial {
            lastSentAt = now
            return .send
        }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignore }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < partialInterval { return .coalesce }
        lastSentAt = now
        return .send
    }

    mutating func markFlushed(at now: Date = Date()) { lastSentAt = now }
}

@MainActor
final class LiveActivityCoordinator: ObservableObject {
    static let shared = LiveActivityCoordinator()

    @Published var liveActivityEnabled: Bool = UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if !liveActivityEnabled { stop() }
        }
    }

    var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return ActivityAuthorizationInfo().areActivitiesEnabled }
        #endif
        return false
    }

    #if canImport(ActivityKit)
    private var activeActivity: Any?
    private var activeLectureID: UUID?
    private var clock = LiveActivityClock(startedAt: Date())
    private var updatePolicy = LiveActivityUpdatePolicy()
    private var pendingPartialTask: Task<Void, Never>?
    private var lastEngineName = "Apple Live"
    private var lastOriginal = ""
    private var lastTranslation = ""
    private var lastRevision = 0
    #endif

    private init() {}

    func start(lectureID: UUID, title: String, engineName: String) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activeLectureID == lectureID, activeActivity is Activity<LectureActivityAttributes> {
            lastEngineName = engineName
            clock.resume()
            publishCurrentState()
            return
        }
        stop()
        activeLectureID = lectureID
        clock = LiveActivityClock(startedAt: Date())
        updatePolicy = LiveActivityUpdatePolicy()
        lastEngineName = engineName
        lastOriginal = ""
        lastTranslation = ""
        lastRevision = 0
        let attributes = LectureActivityAttributes(
            lectureID: lectureID.uuidString,
            lectureTitle: Self.activityTitle(from: title)
        )
        let initialState = contentState()
        do {
            if #available(iOS 16.2, *) {
                activeActivity = try Activity<LectureActivityAttributes>.request(
                    attributes: attributes,
                    content: ActivityContent(state: initialState, staleDate: nil),
                    pushType: nil
                )
            } else {
                activeActivity = try Activity<LectureActivityAttributes>.request(
                    attributes: attributes, contentState: initialState, pushType: nil
                )
            }
        } catch {
            activeLectureID = nil
            print("LiveActivityCoordinator: failed to start activity: \(error.localizedDescription)")
        }
        #endif
    }

    static func activityTitle(from title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.hasPrefix("課堂 ") ? L10n.tr("即時課堂", "Live Lecture") : clean
    }

    func updatePartial(original: String, translation: String, revision: Int) {
        updateCaption(original: original, translation: translation, revision: revision, kind: .meaningfulPartial)
    }

    func updateTranscript(original: String, translation: String, revision: Int? = nil) {
        #if canImport(ActivityKit)
        let isTranslationRevision = !translation.isEmpty && original == lastOriginal
        updateCaption(
            original: original,
            translation: translation,
            revision: revision ?? (isTranslationRevision ? lastRevision : lastRevision + 1),
            kind: isTranslationRevision ? .finalTranslation : .finalOriginal
        )
        #endif
    }

    func updateFinalTranslation(original: String, translation: String, revision: Int) {
        updateCaption(original: original, translation: translation, revision: revision, kind: .finalTranslation)
    }

    private func updateCaption(original: String, translation: String, revision: Int, kind: LiveActivityCaptionKind) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), activeActivity is Activity<LectureActivityAttributes> else { return }
        let now = Date()
        let decision = updatePolicy.accept(kind: kind, revision: revision, original: original, translation: translation, at: now)
        guard decision != .ignore else { return }
        lastOriginal = original
        if !translation.isEmpty { lastTranslation = translation }
        lastRevision = max(lastRevision, revision)
        if decision == .send {
            pendingPartialTask?.cancel()
            pendingPartialTask = nil
            publishCurrentState()
        } else {
            pendingPartialTask?.cancel()
            let delay = max(0.05, updatePolicy.partialInterval - now.timeIntervalSince(updatePolicy.lastSentAt ?? now))
            pendingPartialTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.updatePolicy.markFlushed()
                self.publishCurrentState()
                self.pendingPartialTask = nil
            }
        }
        #endif
    }

    func updatePause(isPaused: Bool, elapsed: TimeInterval) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), activeActivity is Activity<LectureActivityAttributes> else { return }
        pendingPartialTask?.cancel()
        pendingPartialTask = nil
        if isPaused { clock.pause() } else { clock.resume() }
        _ = elapsed // Compatibility input; elapsed seconds are never interpreted as an epoch.
        publishCurrentState()
        #endif
    }

    func stop() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = activeActivity as? Activity<LectureActivityAttributes> else { return }
        pendingPartialTask?.cancel()
        pendingPartialTask = nil
        clock.pause()
        let finalState = contentState(isRecording: false, isPaused: false)
        Task {
            if #available(iOS 16.2, *) {
                await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.end(using: finalState, dismissalPolicy: .immediate)
            }
        }
        activeActivity = nil
        activeLectureID = nil
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private func contentState(isRecording: Bool? = nil, isPaused: Bool? = nil) -> LectureActivityAttributes.ContentState {
        LectureActivityAttributes.ContentState(
            isRecording: isRecording ?? !clock.isPaused,
            isPaused: isPaused ?? clock.isPaused,
            timerReferenceDate: clock.timerReferenceDate,
            elapsedWhenPaused: clock.elapsedWhenPaused,
            latestOriginal: lastOriginal,
            latestTranslation: lastTranslation,
            captionMode: CaptionFeed.shared.captionMode.rawValue,
            recognitionEngineName: lastEngineName,
            captionRevision: lastRevision
        )
    }

    @available(iOS 16.1, *)
    private func publishCurrentState() {
        guard let activity = activeActivity as? Activity<LectureActivityAttributes> else { return }
        let state = contentState()
        print("CaptionLatency activity_update_request=\(Date().timeIntervalSince1970) revision=\(state.captionRevision)")
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
    }
    #endif
}
