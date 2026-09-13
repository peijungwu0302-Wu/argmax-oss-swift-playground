import Foundation

#if canImport(ActivityKit)
import ActivityKit

public struct LectureActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var isRecording: Bool
        public var isPaused: Bool
        public var timerReferenceDate: Date
        public var elapsedWhenPaused: TimeInterval
        public var latestOriginal: String
        public var latestTranslation: String
        public var captionMode: String // "bilingual", "chineseOnly", "originalOnly"
        public var recognitionEngineName: String // e.g. "Apple Live", "Whisper", "SenseVoice"

        public init(
            isRecording: Bool,
            isPaused: Bool,
            timerReferenceDate: Date,
            elapsedWhenPaused: TimeInterval,
            latestOriginal: String,
            latestTranslation: String,
            captionMode: String = "bilingual",
            recognitionEngineName: String = "Apple Live"
        ) {
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.timerReferenceDate = timerReferenceDate
            self.elapsedWhenPaused = elapsedWhenPaused
            self.latestOriginal = latestOriginal
            self.latestTranslation = latestTranslation
            self.captionMode = captionMode
            self.recognitionEngineName = recognitionEngineName
        }
    }

    public var lectureID: String
    public var lectureTitle: String

    public init(lectureID: String, lectureTitle: String) {
        self.lectureID = lectureID
        self.lectureTitle = lectureTitle
    }
}
#endif
