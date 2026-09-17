import Foundation
import Combine

@MainActor
final class CaptionFeed: ObservableObject {
    static let shared = CaptionFeed()

    @Published private(set) var latestOriginal: String = ""
    @Published private(set) var latestTranslation: String = ""
    @Published private(set) var latestCueEndTime: Double?
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var captionMode: PiPDisplayMode = .bilingual
    @Published private(set) var aspectRatio: PiPAspectRatio = .bar
    @Published private(set) var updatedAt: Date = Date()

    var onUpdate: ((CaptionFeed) -> Void)?

    init() {
        if let savedMode = UserDefaults.standard.string(forKey: "pipDisplayMode"),
           let mode = PiPDisplayMode(rawValue: savedMode) {
            self.captionMode = mode
        }
        if let savedRatio = UserDefaults.standard.string(forKey: "pipAspectRatio"),
           let ratio = PiPAspectRatio(rawValue: savedRatio) {
            self.aspectRatio = ratio
        }
    }

    func update(
        original: String? = nil,
        translation: String? = nil,
        isRecording: Bool? = nil,
        isPaused: Bool? = nil,
        captionMode: PiPDisplayMode? = nil,
        aspectRatio: PiPAspectRatio? = nil,
        cueEndTime: Double? = nil
    ) {
        var changed = false
        if let original, original != self.latestOriginal {
            self.latestOriginal = original
            changed = true
        }
        if let translation, translation != self.latestTranslation {
            self.latestTranslation = translation
            changed = true
        }
        if let cueEndTime {
            self.latestCueEndTime = cueEndTime
            changed = true
        }
        if let isRecording, isRecording != self.isRecording {
            self.isRecording = isRecording
            changed = true
        }
        if let isPaused, isPaused != self.isPaused {
            self.isPaused = isPaused
            changed = true
        }
        if let captionMode, captionMode != self.captionMode {
            self.captionMode = captionMode
            UserDefaults.standard.set(captionMode.rawValue, forKey: "pipDisplayMode")
            changed = true
        }
        if let aspectRatio, aspectRatio != self.aspectRatio {
            self.aspectRatio = aspectRatio
            UserDefaults.standard.set(aspectRatio.rawValue, forKey: "pipAspectRatio")
            changed = true
        }

        if changed {
            self.updatedAt = Date()
            onUpdate?(self)
        }
    }

    func clear() {
        latestOriginal = ""
        latestTranslation = ""
        latestCueEndTime = nil
        updatedAt = Date()
        onUpdate?(self)
    }
}
