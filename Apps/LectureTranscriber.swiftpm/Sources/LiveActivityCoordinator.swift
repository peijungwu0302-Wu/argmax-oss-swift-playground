import Foundation
import SwiftUI

#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class LiveActivityCoordinator: ObservableObject {
    static let shared = LiveActivityCoordinator()

    @Published var liveActivityEnabled: Bool = UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if !liveActivityEnabled {
                stop()
            }
        }
    }

    var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    #if canImport(ActivityKit)
    private var activeActivity: Any? // Holds Activity<LectureActivityAttributes>
    private var lastRecordedStartTime: Date = Date()
    private var lastElapsedWhenPaused: TimeInterval = 0
    private var lastEngineName: String = "Apple Live"
    private var lastOriginal: String = ""
    private var lastTranslation: String = ""
    #endif

    private init() {}

    func start(lectureID: UUID, title: String, engineName: String) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Clean up any existing activity before requesting a new one
        stop()

        self.lastRecordedStartTime = Date()
        self.lastElapsedWhenPaused = 0
        self.lastEngineName = engineName
        self.lastOriginal = ""
        self.lastTranslation = ""

        let attributes = LectureActivityAttributes(
            lectureID: lectureID.uuidString,
            lectureTitle: title.isEmpty ? "課堂逐字稿" : title
        )
        let initialState = LectureActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            timerReferenceDate: lastRecordedStartTime,
            elapsedWhenPaused: 0,
            latestOriginal: "",
            latestTranslation: "",
            captionMode: CaptionFeed.shared.captionMode.rawValue,
            recognitionEngineName: engineName
        )

        do {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: initialState, staleDate: nil)
                let activity = try Activity<LectureActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                self.activeActivity = activity
            } else {
                let activity = try Activity<LectureActivityAttributes>.request(
                    attributes: attributes,
                    contentState: initialState,
                    pushType: nil
                )
                self.activeActivity = activity
            }
            print("LiveActivityCoordinator: started activity successfully")
        } catch {
            print("LiveActivityCoordinator: failed to start activity: \(error.localizedDescription)")
        }
        #endif
    }

    func updateTranscript(original: String, translation: String) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = activeActivity as? Activity<LectureActivityAttributes> else { return }

        // Only update if there is meaningful new finalized text
        if original == lastOriginal && translation == lastTranslation { return }
        self.lastOriginal = original
        self.lastTranslation = translation

        let state = LectureActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            timerReferenceDate: lastRecordedStartTime,
            elapsedWhenPaused: lastElapsedWhenPaused,
            latestOriginal: original,
            latestTranslation: translation,
            captionMode: CaptionFeed.shared.captionMode.rawValue,
            recognitionEngineName: lastEngineName
        )

        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
        #endif
    }

    func updatePause(isPaused: Bool, elapsed: TimeInterval) {
        guard liveActivityEnabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = activeActivity as? Activity<LectureActivityAttributes> else { return }

        self.lastElapsedWhenPaused = elapsed
        if !isPaused {
            // When resuming, shift the timer reference date backwards by the accumulated elapsed seconds
            self.lastRecordedStartTime = Date().addingTimeInterval(-elapsed)
        }

        let state = LectureActivityAttributes.ContentState(
            isRecording: !isPaused,
            isPaused: isPaused,
            timerReferenceDate: lastRecordedStartTime,
            elapsedWhenPaused: elapsed,
            latestOriginal: lastOriginal,
            latestTranslation: lastTranslation,
            captionMode: CaptionFeed.shared.captionMode.rawValue,
            recognitionEngineName: lastEngineName
        )

        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
        #endif
    }

    func stop() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = activeActivity as? Activity<LectureActivityAttributes> else { return }

        let finalState = LectureActivityAttributes.ContentState(
            isRecording: false,
            isPaused: false,
            timerReferenceDate: lastRecordedStartTime,
            elapsedWhenPaused: lastElapsedWhenPaused,
            latestOriginal: lastOriginal,
            latestTranslation: lastTranslation,
            captionMode: CaptionFeed.shared.captionMode.rawValue,
            recognitionEngineName: lastEngineName
        )

        Task {
            if #available(iOS 16.2, *) {
                await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.end(using: finalState, dismissalPolicy: .immediate)
            }
        }
        self.activeActivity = nil
        #endif
    }
}
