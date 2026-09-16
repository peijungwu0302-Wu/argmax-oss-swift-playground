import Foundation
import UIKit
import CoreGraphics

// MARK: - Caption Presentation Model

public struct CaptionPresentationModel: Equatable {
    public var originalText: String
    public var translatedText: String
    public var displayMode: PiPDisplayMode
    public var fontScale: Double
    public var translationFontScale: Double
    public var aspectRatio: PiPAspectRatio
    public var alignment: NSTextAlignment
    public var verticalPosition: PiPVerticalPosition
    public var isSamplePreview: Bool

    public init(
        originalText: String = "",
        translatedText: String = "",
        displayMode: PiPDisplayMode = .bilingual,
        fontScale: Double = 1.0,
        translationFontScale: Double = 1.0,
        aspectRatio: PiPAspectRatio = .bar,
        alignment: NSTextAlignment = .left,
        verticalPosition: PiPVerticalPosition = .center,
        isSamplePreview: Bool = false
    ) {
        self.originalText = originalText
        self.translatedText = translatedText
        self.displayMode = displayMode
        self.fontScale = fontScale
        self.translationFontScale = translationFontScale
        self.aspectRatio = aspectRatio
        self.alignment = alignment
        self.verticalPosition = verticalPosition
        self.isSamplePreview = isSamplePreview
    }
}

// MARK: - Measured Layout Rectangles

public struct PiPMeasuredLayout {
    public var originalRect: CGRect?
    public var originalTextToDraw: String
    public var originalFont: UIFont
    public var originalColor: UIColor

    public var translationRect: CGRect?
    public var translationTextToDraw: String
    public var translationFont: UIFont
    public var translationColor: UIColor

    public var paragraphStyle: NSParagraphStyle
}

// MARK: - PiP Caption Layout Engine

/// Real measurement-based layout engine for Picture in Picture captions.
/// Solves the text clipping / truncation bug without shrinking user font size or discarding transcript data.
/// Uses measured geometry, adaptive bilingual space allocation, and a rolling/tail window for long sentences.
public final class PiPCaptionLayoutEngine {
    public static let shared = PiPCaptionLayoutEngine()

    // Smooth moving average for bilingual allocation ratio to prevent bouncing
    private var lastAllocatedOrigRatio: CGFloat = 0.46

    public init() {}

    public func layout(
        model: CaptionPresentationModel,
        canvasSize: CGSize,
        metrics: PiPLayoutMetrics
    ) -> PiPMeasuredLayout {
        let width = canvasSize.width
        let height = canvasSize.height
        let hPadding = metrics.horizontalPadding
        let textWidth = max(50, width - (hPadding * 2))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = model.alignment
        paragraph.lineSpacing = metrics.lineSpacing

        let origFont = UIFont.systemFont(ofSize: metrics.originalFont, weight: .regular)
        let transFont = UIFont.systemFont(ofSize: metrics.translationFont, weight: .semibold)
        let origColor = UIColor.white
        let transColor = UIColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1.0) // Gold

        let origText = model.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transText = model.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch model.displayMode {
        case .originalOnly:
            let availableHeight = max(20, height - metrics.verticalPadding * 2)
            let rollingText = tailWindow(
                for: origText,
                font: origFont,
                maxWidth: textWidth,
                maxHeight: availableHeight,
                paragraphStyle: paragraph
            )
            let measuredSize = measureText(rollingText, font: origFont, maxWidth: textWidth, paragraphStyle: paragraph)
            let rect = alignBlock(
                height: min(availableHeight, measuredSize.height),
                canvasHeight: height,
                metrics: metrics,
                position: model.verticalPosition,
                hPadding: hPadding,
                textWidth: textWidth
            )
            return PiPMeasuredLayout(
                originalRect: rect,
                originalTextToDraw: rollingText,
                originalFont: origFont,
                originalColor: origColor,
                translationRect: nil,
                translationTextToDraw: "",
                translationFont: transFont,
                translationColor: transColor,
                paragraphStyle: paragraph
            )

        case .chineseOnly:
            let textToDisplay = transText.isEmpty ? origText : transText
            let fontToUse = transText.isEmpty ? origFont : transFont
            let colorToUse = transText.isEmpty ? origColor : transColor
            let availableHeight = max(20, height - metrics.verticalPadding * 2)
            let rollingText = tailWindow(
                for: textToDisplay,
                font: fontToUse,
                maxWidth: textWidth,
                maxHeight: availableHeight,
                paragraphStyle: paragraph
            )
            let measuredSize = measureText(rollingText, font: fontToUse, maxWidth: textWidth, paragraphStyle: paragraph)
            let rect = alignBlock(
                height: min(availableHeight, measuredSize.height),
                canvasHeight: height,
                metrics: metrics,
                position: model.verticalPosition,
                hPadding: hPadding,
                textWidth: textWidth
            )
            return PiPMeasuredLayout(
                originalRect: nil,
                originalTextToDraw: "",
                originalFont: origFont,
                originalColor: origColor,
                translationRect: rect,
                translationTextToDraw: rollingText,
                translationFont: fontToUse,
                translationColor: colorToUse,
                paragraphStyle: paragraph
            )

        case .bilingual:
            if transText.isEmpty {
                // No translation yet; display original cleanly centered
                let availableHeight = max(20, height - metrics.verticalPadding * 2)
                let rollingOrig = tailWindow(
                    for: origText,
                    font: origFont,
                    maxWidth: textWidth,
                    maxHeight: availableHeight,
                    paragraphStyle: paragraph
                )
                let measured = measureText(rollingOrig, font: origFont, maxWidth: textWidth, paragraphStyle: paragraph)
                let rect = alignBlock(
                    height: min(availableHeight, measured.height),
                    canvasHeight: height,
                    metrics: metrics,
                    position: model.verticalPosition,
                    hPadding: hPadding,
                    textWidth: textWidth
                )
                return PiPMeasuredLayout(
                    originalRect: rect,
                    originalTextToDraw: rollingOrig,
                    originalFont: origFont,
                    originalColor: origColor,
                    translationRect: nil,
                    translationTextToDraw: "",
                    translationFont: transFont,
                    translationColor: transColor,
                    paragraphStyle: paragraph
                )
            } else {
                // Adaptive height allocation
                let totalAvail = max(30, height - metrics.verticalPadding * 2 - metrics.blockGap)
                let unconstrainedOrig = measureText(origText, font: origFont, maxWidth: textWidth, paragraphStyle: paragraph).height
                let unconstrainedTrans = measureText(transText, font: transFont, maxWidth: textWidth, paragraphStyle: paragraph).height

                let origRatio: CGFloat
                if unconstrainedOrig + unconstrainedTrans <= totalAvail {
                    origRatio = unconstrainedOrig / max(1, unconstrainedOrig + unconstrainedTrans)
                } else {
                    // Bounded adaptive allocation: guarantee at least 30% for original, 30% for translation
                    let rawRatio = unconstrainedOrig / max(1, unconstrainedOrig + unconstrainedTrans)
                    origRatio = min(0.65, max(0.35, rawRatio))
                }

                // Low-pass filter to prevent layout jitter on partial tokens
                let smoothedRatio = lastAllocatedOrigRatio * 0.7 + origRatio * 0.3
                lastAllocatedOrigRatio = smoothedRatio

                let origHeight = totalAvail * smoothedRatio
                let transHeight = totalAvail - origHeight

                let rollingOrig = tailWindow(
                    for: origText,
                    font: origFont,
                    maxWidth: textWidth,
                    maxHeight: origHeight,
                    paragraphStyle: paragraph
                )
                let rollingTrans = tailWindow(
                    for: transText,
                    font: transFont,
                    maxWidth: textWidth,
                    maxHeight: transHeight,
                    paragraphStyle: paragraph
                )

                let measuredOrigH = min(origHeight, measureText(rollingOrig, font: origFont, maxWidth: textWidth, paragraphStyle: paragraph).height)
                let measuredTransH = min(transHeight, measureText(rollingTrans, font: transFont, maxWidth: textWidth, paragraphStyle: paragraph).height)
                let combinedH = measuredOrigH + metrics.blockGap + measuredTransH

                let block = alignBlock(
                    height: combinedH,
                    canvasHeight: height,
                    metrics: metrics,
                    position: model.verticalPosition,
                    hPadding: hPadding,
                    textWidth: textWidth
                )

                let origRect = CGRect(x: hPadding, y: block.minY, width: textWidth, height: measuredOrigH)
                let transRect = CGRect(x: hPadding, y: origRect.maxY + metrics.blockGap, width: textWidth, height: measuredTransH)

                return PiPMeasuredLayout(
                    originalRect: origRect,
                    originalTextToDraw: rollingOrig,
                    originalFont: origFont,
                    originalColor: origColor,
                    translationRect: transRect,
                    translationTextToDraw: rollingTrans,
                    translationFont: transFont,
                    translationColor: transColor,
                    paragraphStyle: paragraph
                )
            }
        }
    }

    // MARK: - Rolling Tail Window

    /// Returns the tail-window substring of text that completely fits within maxHeight,
    /// ensuring newest words remain visible when content exceeds PiP capacity.
    public func tailWindow(
        for text: String,
        font: UIFont,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        paragraphStyle: NSParagraphStyle
    ) -> String {
        guard !text.isEmpty else { return text }

        let fullSize = measureText(text, font: font, maxWidth: maxWidth, paragraphStyle: paragraphStyle)
        if fullSize.height <= maxHeight {
            return text
        }

        // Determine segmentation unit: if mostly Latin/English use words; if CJK use characters
        let hasSpaces = text.contains(" ")
        let isCJK = text.unicodeScalars.contains { CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains($0) }

        if !isCJK && hasSpaces {
            // Word-boundary rolling window
            let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            var low = 0
            var high = words.count - 1
            var bestTail = text

            while low <= high {
                let mid = (low + high) / 2
                let candidateWords = Array(words[mid...])
                let candidate = (mid > 0 ? "… " : "") + candidateWords.joined(separator: " ")
                let h = measureText(candidate, font: font, maxWidth: maxWidth, paragraphStyle: paragraphStyle).height
                if h <= maxHeight {
                    bestTail = candidate
                    high = mid - 1 // Try to include more words from earlier
                } else {
                    low = mid + 1 // Too tall; move tail forward
                }
            }
            return bestTail
        } else {
            // Grapheme/character-boundary rolling window
            let characters = Array(text)
            var low = 0
            var high = characters.count - 1
            var bestTail = text

            while low <= high {
                let mid = (low + high) / 2
                let candidateChars = Array(characters[mid...])
                let candidate = (mid > 0 ? "… " : "") + String(candidateChars)
                let h = measureText(candidate, font: font, maxWidth: maxWidth, paragraphStyle: paragraphStyle).height
                if h <= maxHeight {
                    bestTail = candidate
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
            return bestTail
        }
    }

    // MARK: - Geometry Measurement

    public func measureText(
        _ text: String,
        font: UIFont,
        maxWidth: CGFloat,
        paragraphStyle: NSParagraphStyle
    ) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private func alignBlock(
        height: CGFloat,
        canvasHeight: CGFloat,
        metrics: PiPLayoutMetrics,
        position: PiPVerticalPosition,
        hPadding: CGFloat,
        textWidth: CGFloat
    ) -> CGRect {
        let y: CGFloat
        switch position {
        case .top:
            y = metrics.verticalPadding
        case .center:
            y = max(metrics.verticalPadding, (canvasHeight - height) / 2)
        case .bottom:
            y = max(metrics.verticalPadding, canvasHeight - metrics.verticalPadding - height)
        }
        return CGRect(x: hPadding, y: y, width: textWidth, height: height)
    }
}
