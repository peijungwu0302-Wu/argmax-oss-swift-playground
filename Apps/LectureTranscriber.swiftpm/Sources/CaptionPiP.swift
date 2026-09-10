import SwiftUI
import AVKit
import CoreMedia
import CoreVideo

final class CaptionVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@MainActor final class CaptionPiP: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var paused = false
    @Published private(set) var status = ""
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
            status = "此環境不支援子母畫面，請使用精簡視窗字幕。"; return
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
        status = "子母畫面為 beta；請保持此預覽可見後啟動。"
    }
    func detach() {
        pip?.stopPictureInPicture(); pip?.delegate = nil; pip = nil
        observation = nil; timer?.invalidate(); timer = nil; surface = nil
        active = false; possible = false; paused = false
    }
    func update(original: String, translated: String, sourceSize: Double, translationSize: Double) {
        self.original = original.isEmpty ? "等待語音…" : original; self.translated = translated
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
                status = "系統尚未允許子母畫面；請保持預覽可見，或改用精簡小視窗。"; return
            }
            pip.startPictureInPicture()
        } catch { status = "子母畫面啟動失敗：" + error.localizedDescription }
    }
    func stop() { pip?.stopPictureInPicture() }

    private func render() {
        guard !paused, let layer = surface?.displayLayer else { return }
        let width = 960, height = 320
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attributes, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        context.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let topHeight: CGFloat = translated.isEmpty ? 280 : 152
        (original as NSString).draw(in: CGRect(x: 24, y: 14, width: 912, height: topHeight), withAttributes: [
            .font: UIFont.systemFont(ofSize: min(72, sourceSize * 2), weight: .medium), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        (translated as NSString).draw(in: CGRect(x: 24, y: 176, width: 912, height: 130), withAttributes: [
            .font: UIFont.systemFont(ofSize: min(64, translationSize * 2)), .foregroundColor: UIColor.systemYellow, .paragraphStyle: paragraph])
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
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { active = false; status = error.localizedDescription }
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
