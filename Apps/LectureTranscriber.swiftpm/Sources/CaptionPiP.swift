import SwiftUI
import AVKit
import CoreMedia
import CoreVideo

final class CaptionVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

enum PiPDisplayMode: String, CaseIterable, Identifiable, Codable {
    case bilingual = "bilingual"
    case chineseOnly = "chineseOnly"
    case originalOnly = "originalOnly"

    static let translationOnly = PiPDisplayMode.chineseOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bilingual: return L10n.tr("雙語（原文 + 繁中）", "Bilingual (Original + Chinese)")
        case .chineseOnly: return L10n.tr("僅翻譯（繁體中文）", "Translation Only")
        case .originalOnly: return L10n.tr("僅原文", "Original Only")
        }
    }
}

@MainActor final class CaptionPiP: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var paused = false
    @Published private(set) var status = ""
    @Published var displayMode: PiPDisplayMode = .bilingual
    private var pip: AVPictureInPictureController?
    private weak var surface: CaptionVideoView?
    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var original = "等待語音…", translated = ""
    private var sourceSize = 25.0, translationSize = 20.0

    func attach(_ view: CaptionVideoView) {
        guard surface !== view else { return }
        detach()
        surface = view
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            view.displayLayer.controlTimebase = timebase
        }
        view.displayLayer.videoGravity = .resizeAspect
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            status = L10n.tr("此環境不支援子母畫面，請使用精簡視窗字幕。", "Picture in Picture not supported in this environment.")
            return
        }
        pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self))
        pip?.delegate = self; pip?.requiresLinearPlayback = true
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        observation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, value in
            Task { @MainActor in self?.possible = value.newValue ?? false }
        }
        render()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.render() } }
        RunLoop.main.add(timer!, forMode: .common)
        status = L10n.tr("子母畫面為 beta；請保持此預覽可見後啟動。", "PiP is in beta; keep this preview visible then start.")
    }
    func detach() {
        pip?.stopPictureInPicture(); pip?.delegate = nil; pip = nil
        observation = nil; timer?.invalidate(); timer = nil; surface = nil
        active = false; possible = false; paused = false
    }
    func update(original: String, translated: String, sourceSize: Double, translationSize: Double) {
        self.original = original.isEmpty ? L10n.tr("等待語音…", "Waiting for speech…") : original; self.translated = translated
        self.sourceSize = sourceSize; self.translationSize = translationSize; render()
    }
    func start(recording: Bool) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(recording ? .playAndRecord : .playback, mode: recording ? .measurement : .default,
                                  options: recording ? [.defaultToSpeaker, .mixWithOthers] : [.mixWithOthers])
            try audio.setActive(true)
            render()
            guard let pip, pip.isPictureInPicturePossible else {
                status = L10n.tr("系統尚未允許子母畫面；請保持預覽可見，或改用精簡小視窗。", "System has not allowed PiP yet; keep preview visible or use compact window.")
                return
            }
            pip.startPictureInPicture()
        } catch { status = L10n.tr("子母畫面啟動失敗：", "Failed to start PiP: ") + error.localizedDescription }
    }
    func stop() { pip?.stopPictureInPicture() }

    private func render() {
        guard !paused, let layer = surface?.displayLayer else { return }
        // 5:1 Aspect Ratio Subtitle Bar: 1200 x 240
        let width = 1200, height = 240
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attributes, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        // Solid high-contrast dark background
        context.setFillColor(UIColor(white: 0.07, alpha: 0.96).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        paragraph.lineSpacing = 4

        let horizontalPadding: CGFloat = 36
        let textWidth = CGFloat(width) - (horizontalPadding * 2)

        switch displayMode {
        case .chineseOnly:
            let textToDraw = translated.isEmpty ? original : translated
            let fontSize = min(54.0, max(28.0, translationSize * 2.0))
            (textToDraw as NSString).draw(in: CGRect(x: horizontalPadding, y: 32, width: textWidth, height: CGFloat(height) - 64), withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0),
                .paragraphStyle: paragraph
            ])
        case .originalOnly:
            let fontSize = min(54.0, max(28.0, sourceSize * 2.0))
            (original as NSString).draw(in: CGRect(x: horizontalPadding, y: 32, width: textWidth, height: CGFloat(height) - 64), withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ])
        case .bilingual:
            if translated.isEmpty {
                let fontSize = min(50.0, max(28.0, sourceSize * 2.0))
                (original as NSString).draw(in: CGRect(x: horizontalPadding, y: 36, width: textWidth, height: CGFloat(height) - 72), withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ])
            } else {
                let origFontSize = min(38.0, max(22.0, sourceSize * 1.5))
                let transFontSize = min(40.0, max(24.0, translationSize * 1.6))

                (original as NSString).draw(in: CGRect(x: horizontalPadding, y: 20, width: textWidth, height: 96), withAttributes: [
                    .font: UIFont.systemFont(ofSize: origFontSize, weight: .regular),
                    .foregroundColor: UIColor(white: 0.90, alpha: 1.0),
                    .paragraphStyle: paragraph
                ])
                (translated as NSString).draw(in: CGRect(x: horizontalPadding, y: 122, width: textWidth, height: 98), withAttributes: [
                    .font: UIFont.systemFont(ofSize: transFontSize, weight: .semibold),
                    .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0),
                    .paragraphStyle: paragraph
                ])
            }
        }
        UIGraphicsPopContext()
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing; render(); pictureInPictureController.invalidatePlaybackState()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { paused }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { render() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = true; status = "子母畫面字幕已啟動" }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = false; paused = false }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.active = false
            self.status = error.localizedDescription
        }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

struct CaptionPiPPreview: UIViewRepresentable {
    @ObservedObject var pip: CaptionPiP
    var original: String
    var translated: String
    var sourceSize: Double
    var translationSize: Double
    func makeUIView(context: Context) -> CaptionVideoView {
        let view = CaptionVideoView(); pip.attach(view); return view
    }
    func updateUIView(_ view: CaptionVideoView, context: Context) {
        pip.update(original: original, translated: translated, sourceSize: sourceSize, translationSize: translationSize)
    }
    static func dismantleUIView(_ view: CaptionVideoView, coordinator: ()) { view.displayLayer.flushAndRemoveImage() }
}

struct CompactWindowSizing: UIViewRepresentable {
    var compact: Bool
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            // Public API is advisory and may be nil in unsupported window modes.
            view.window?.windowScene?.sizeRestrictions?.minimumSize = compact ? CGSize(width: 280, height: 140) : CGSize(width: 320, height: 320)
        }
    }
}
