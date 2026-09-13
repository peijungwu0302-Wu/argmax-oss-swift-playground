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

enum PiPAspectRatio: String, CaseIterable, Identifiable, Codable {
    case standard = "3:1"
    case bar = "5:1"
    case ultraWide = "6:1"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return L10n.tr("標準（3:1）", "Standard (3:1)")
        case .bar: return L10n.tr("字幕條（5:1，預設）", "Subtitle Bar (5:1, Default)")
        case .ultraWide: return L10n.tr("超寬（6:1）", "Ultra-wide (6:1)")
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .standard: return (960, 320)
        case .bar: return (1200, 240)
        case .ultraWide: return (1200, 200)
        }
    }
}

@MainActor
final class CaptionPiP: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var paused = false
    @Published private(set) var status = ""
    @Published var displayMode: PiPDisplayMode = .bilingual {
        didSet {
            CaptionFeed.shared.update(captionMode: displayMode)
            render(force: true)
        }
    }
    @Published var aspectRatio: PiPAspectRatio = .bar {
        didSet {
            CaptionFeed.shared.update(aspectRatio: aspectRatio)
            render(force: true)
        }
    }
    @Published var isStaticTest: Bool = false {
        didSet { render(force: true) }
    }

    private var pip: AVPictureInPictureController?
    private weak var surface: CaptionVideoView?
    private var observation: NSKeyValueObservation?
    private var original = "等待語音…", translated = ""
    private var sourceSize = 25.0, translationSize = 20.0
    private var currentRenderSize: CGSize?
    private var lastRenderedOriginal = ""
    private var lastRenderedTranslation = ""
    private var lastRenderedMode: PiPDisplayMode?
    private var lastRenderedRatio: PiPAspectRatio?
    private var lastRenderedStaticTest: Bool?

    override init() {
        super.init()
        let feed = CaptionFeed.shared
        self.displayMode = feed.captionMode
        self.aspectRatio = feed.aspectRatio
        feed.onUpdate = { [weak self] updatedFeed in
            self?.feedDidUpdate(updatedFeed)
        }
    }

    private func feedDidUpdate(_ feed: CaptionFeed) {
        let orig = feed.latestOriginal.isEmpty ? L10n.tr("等待語音…", "Waiting for speech…") : feed.latestOriginal
        let trans = feed.latestTranslation
        let mode = feed.captionMode
        let ratio = feed.aspectRatio
        var needsRender = false

        if orig != self.original || trans != self.translated {
            self.original = orig
            self.translated = trans
            needsRender = true
        }
        if mode != self.displayMode {
            self.displayMode = mode
            needsRender = true
        }
        if ratio != self.aspectRatio {
            self.aspectRatio = ratio
            needsRender = true
        }
        if needsRender {
            render()
        }
    }

    func attach(_ view: CaptionVideoView) {
        guard surface !== view else { return }
        detach()
        surface = view

        // Configure display layer for hardware-accelerated subtitle presentation
        view.displayLayer.videoGravity = .resizeAspect
        view.displayLayer.preventsDisplaySleepDuringVideoPlayback = true

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            status = L10n.tr("此環境不支援子母畫面，請使用精簡視窗字幕。", "Picture in Picture not supported in this environment.")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: view.displayLayer,
            playbackDelegate: self
        )
        let pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController.delegate = self
        pipController.requiresLinearPlayback = true
        pipController.canStartPictureInPictureAutomaticallyFromInline = false

        observation = pipController.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, value in
            Task { @MainActor in self?.possible = value.newValue ?? false }
        }
        self.pip = pipController

        render(force: true)
        status = L10n.tr("子母畫面就緒；點擊啟動即可懸浮顯示字幕。", "PiP ready; tap to launch floating captions.")
    }

    func detach() {
        pip?.stopPictureInPicture()
        pip?.delegate = nil
        pip = nil
        observation = nil
        surface = nil
        active = false
        possible = false
        paused = false
    }

    func update(original: String, translated: String, sourceSize: Double, translationSize: Double) {
        self.sourceSize = sourceSize
        self.translationSize = translationSize
        let resolvedOriginal = original.isEmpty ? L10n.tr("等待語音…", "Waiting for speech…") : original
        if resolvedOriginal != self.original || translated != self.translated {
            self.original = resolvedOriginal
            self.translated = translated
            render()
        }
    }

    func start(recording: Bool) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(
                recording ? .playAndRecord : .playback,
                mode: recording ? .measurement : .default,
                options: recording ? [.defaultToSpeaker, .mixWithOthers, .allowBluetooth] : [.mixWithOthers]
            )
            try audio.setActive(true)
            render(force: true)
            guard let pip, pip.isPictureInPicturePossible else {
                status = L10n.tr("系統尚未允許子母畫面；請稍候再試或改用精簡小視窗。", "System has not allowed PiP yet; keep preview visible or use compact window.")
                return
            }
            pip.startPictureInPicture()
        } catch {
            status = L10n.tr("子母畫面啟動失敗：", "Failed to start PiP: ") + error.localizedDescription
        }
    }

    func stop() {
        pip?.stopPictureInPicture()
    }

    func setStaticTest(_ enabled: Bool) {
        self.isStaticTest = enabled
    }

    func render(force: Bool = false) {
        guard !paused, let layer = surface?.displayLayer else { return }

        // Skip render if nothing changed and not forced
        if !force,
           original == lastRenderedOriginal,
           translated == lastRenderedTranslation,
           displayMode == lastRenderedMode,
           aspectRatio == lastRenderedRatio,
           isStaticTest == lastRenderedStaticTest {
            return
        }

        let dims = aspectRatio.dimensions
        let width = dims.width
        let height = dims.height

        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixel
        )
        guard createStatus == kCVReturnSuccess, let pixel else {
            print("CaptionPiP: CVPixelBufferCreate failed with error: \(createStatus)")
            return
        }

        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixel) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixel)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            print("CaptionPiP: CGContext initialization failed")
            return
        }

        // Draw solid high-contrast dark background (#141414)
        context.setFillColor(UIColor(white: 0.08, alpha: 0.98).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip coordinates for UIKit text drawing
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        paragraph.lineSpacing = 4

        let horizontalPadding: CGFloat = 36
        let textWidth = CGFloat(width) - (horizontalPadding * 2)

        if isStaticTest {
            // TEST P1: Static Renderer Test
            let testParagraph = NSMutableParagraphStyle()
            testParagraph.alignment = .center
            testParagraph.lineSpacing = 8

            let titleRect = CGRect(x: horizontalPadding, y: CGFloat(height) * 0.15, width: textWidth, height: CGFloat(height) * 0.35)
            let subRect = CGRect(x: horizontalPadding, y: CGFloat(height) * 0.52, width: textWidth, height: CGFloat(height) * 0.35)

            ("PIP TEST" as NSString).draw(in: titleRect, withAttributes: [
                .font: UIFont.systemFont(ofSize: min(56.0, CGFloat(height) * 0.28), weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: testParagraph
            ])
            ("測試字幕 123" as NSString).draw(in: subRect, withAttributes: [
                .font: UIFont.systemFont(ofSize: min(48.0, CGFloat(height) * 0.24), weight: .bold),
                .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0),
                .paragraphStyle: testParagraph
            ])
        } else {
            switch displayMode {
            case .chineseOnly:
                let textToDraw = translated.isEmpty ? original : translated
                let fontSize = min(54.0, max(26.0, translationSize * (CGFloat(height) / 120.0)))
                let rect = CGRect(x: horizontalPadding, y: 28, width: textWidth, height: CGFloat(height) - 56)
                (textToDraw as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0),
                    .paragraphStyle: paragraph
                ])

            case .originalOnly:
                let fontSize = min(54.0, max(26.0, sourceSize * (CGFloat(height) / 120.0)))
                let rect = CGRect(x: horizontalPadding, y: 28, width: textWidth, height: CGFloat(height) - 56)
                (original as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ])

            case .bilingual:
                if translated.isEmpty {
                    let fontSize = min(50.0, max(26.0, sourceSize * (CGFloat(height) / 120.0)))
                    let rect = CGRect(x: horizontalPadding, y: 32, width: textWidth, height: CGFloat(height) - 64)
                    (original as NSString).draw(in: rect, withAttributes: [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                        .foregroundColor: UIColor.white,
                        .paragraphStyle: paragraph
                    ])
                } else {
                    let ratioScale = CGFloat(height) / 240.0
                    let origFontSize = min(40.0, max(20.0, sourceSize * 1.4 * ratioScale))
                    let transFontSize = min(42.0, max(22.0, translationSize * 1.5 * ratioScale))

                    let origHeight = (CGFloat(height) - 40) * 0.44
                    let transHeight = (CGFloat(height) - 40) * 0.56
                    let origY: CGFloat = 16
                    let transY: CGFloat = origY + origHeight + 8

                    (original as NSString).draw(in: CGRect(x: horizontalPadding, y: origY, width: textWidth, height: origHeight), withAttributes: [
                        .font: UIFont.systemFont(ofSize: origFontSize, weight: .regular),
                        .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
                        .paragraphStyle: paragraph
                    ])
                    (translated as NSString).draw(in: CGRect(x: horizontalPadding, y: transY, width: textWidth, height: transHeight), withAttributes: [
                        .font: UIFont.systemFont(ofSize: transFontSize, weight: .semibold),
                        .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0),
                        .paragraphStyle: paragraph
                    ])
                }
            }
        }
        UIGraphicsPopContext()

        var format: CMVideoFormatDescription?
        let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescriptionOut: &format
        )
        guard formatResult == noErr, let format else {
            print("CaptionPiP: CMVideoFormatDescriptionCreateForImageBuffer failed: \(formatResult)")
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixel,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleResult == noErr, let sample else {
            print("CaptionPiP: CMSampleBufferCreateReadyWithImageBuffer failed: \(sampleResult)")
            return
        }

        // DisplayImmediately attachment: Essential for un-timed subtitle/caption presentation in AVSampleBufferDisplayLayer
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            for i in 0..<count {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        if layer.status == .failed {
            print("CaptionPiP: displayLayer failed (error: \(String(describing: layer.error))), flushing...")
            layer.flush()
        }

        if layer.isReadyForMoreMediaData {
            layer.enqueue(sample)
            lastRenderedOriginal = original
            lastRenderedTranslation = translated
            lastRenderedMode = displayMode
            lastRenderedRatio = aspectRatio
            lastRenderedStaticTest = isStaticTest
        }
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing
        render(force: true)
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        self.currentRenderSize = CGSize(width: CGFloat(newRenderSize.width), height: CGFloat(newRenderSize.height))
        render(force: true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion()
    }

    // MARK: - AVPictureInPictureControllerDelegate
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        active = true
        status = L10n.tr("子母畫面字幕已啟動", "PiP captions active")
        render(force: true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        active = false
        paused = false
        status = L10n.tr("子母畫面字幕已結束", "PiP captions stopped")
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.active = false
            self.status = error.localizedDescription
            print("CaptionPiP failedToStart: \(error)")
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

struct CaptionPiPPreview: UIViewRepresentable {
    @ObservedObject var pip: CaptionPiP
    var original: String
    var translated: String
    var sourceSize: Double
    var translationSize: Double

    func makeUIView(context: Context) -> CaptionVideoView {
        let view = CaptionVideoView()
        pip.attach(view)
        return view
    }

    func updateUIView(_ view: CaptionVideoView, context: Context) {
        pip.update(original: original, translated: translated, sourceSize: sourceSize, translationSize: translationSize)
    }

    static func dismantleUIView(_ view: CaptionVideoView, coordinator: ()) {
        // Do NOT call view.displayLayer.flushAndRemoveImage() here!
        // Preserving the display layer frame prevents blanking out the active PiP window
        // when views are transitioned or moved into the background.
    }
}

struct CompactWindowSizing: UIViewRepresentable {
    var compact: Bool
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            view.window?.windowScene?.sizeRestrictions?.minimumSize = compact ? CGSize(width: 280, height: 140) : CGSize(width: 320, height: 320)
        }
    }
}
