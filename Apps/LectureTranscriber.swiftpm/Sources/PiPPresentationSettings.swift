import Foundation
import SwiftUI
import UIKit

enum PiPTextAlignment: String, CaseIterable, Identifiable, Codable {
    case left, center, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return L10n.tr("靠左", "Left")
        case .center: return L10n.tr("置中", "Center")
        case .right: return L10n.tr("靠右", "Right")
        }
    }
    var nsAlignment: NSTextAlignment {
        switch self { case .left: return .left; case .center: return .center; case .right: return .right }
    }
}

enum PiPVerticalPosition: String, CaseIterable, Identifiable, Codable {
    case top, center, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return L10n.tr("上方", "Top")
        case .center: return L10n.tr("置中", "Center")
        case .bottom: return L10n.tr("下方", "Bottom")
        }
    }
}

enum PiPCaptionGap: String, CaseIterable, Identifiable, Codable {
    case compact, standard, wide
    var id: String { rawValue }
    var points: CGFloat { switch self { case .compact: return 4; case .standard: return 8; case .wide: return 16 } }
    var title: String {
        switch self {
        case .compact: return L10n.tr("緊湊", "Compact")
        case .standard: return L10n.tr("標準", "Standard")
        case .wide: return L10n.tr("寬鬆", "Wide")
        }
    }
}

@MainActor
final class PiPPresentationSettings: ObservableObject {
    static let shared = PiPPresentationSettings()
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var autoStart: Bool { didSet { save(autoStart, "pipAutoStart") } }
    @Published var aspectRatio: PiPAspectRatio { didSet { save(aspectRatio.rawValue, "pipAspectRatio") } }
    @Published var aspectRatioValue: Double {
        didSet {
            let clamped = min(8, max(2.5, aspectRatioValue))
            if clamped != aspectRatioValue { aspectRatioValue = clamped; return }
            save(aspectRatioValue, "pipAspectRatioValue")
        }
    }
    @Published var fontScale: Double {
        didSet {
            let clamped = min(3, max(0.3, fontScale))
            if clamped != fontScale { fontScale = clamped; return }
            save(fontScale, "pipFontScale")
        }
    }
    @Published var captionMode: PiPDisplayMode { didSet { save(captionMode.rawValue, "pipDisplayMode") } }
    @Published var alignment: PiPTextAlignment { didSet { save(alignment.rawValue, "pipTextAlignment") } }
    @Published var verticalPosition: PiPVerticalPosition { didSet { save(verticalPosition.rawValue, "pipVerticalPosition") } }
    @Published var gap: PiPCaptionGap { didSet { save(gap.rawValue, "pipCaptionGap") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoStart = defaults.object(forKey: "pipAutoStart") as? Bool ?? true
        aspectRatio = PiPAspectRatio(rawValue: defaults.string(forKey: "pipAspectRatio") ?? "") ?? .bar
        aspectRatioValue = min(8, max(2.5, defaults.object(forKey: "pipAspectRatioValue") as? Double ?? 5))
        let storedScale = defaults.object(forKey: "pipFontScale") as? Double
        fontScale = min(3, max(0.3, storedScale ?? 1))
        captionMode = PiPDisplayMode(rawValue: defaults.string(forKey: "pipDisplayMode") ?? "") ?? .bilingual
        alignment = PiPTextAlignment(rawValue: defaults.string(forKey: "pipTextAlignment") ?? "") ?? .left
        verticalPosition = PiPVerticalPosition(rawValue: defaults.string(forKey: "pipVerticalPosition") ?? "") ?? .center
        gap = PiPCaptionGap(rawValue: defaults.string(forKey: "pipCaptionGap") ?? "") ?? .standard
    }

    func reset() {
        autoStart = true
        aspectRatio = .bar
        aspectRatioValue = 5
        fontScale = 1
        captionMode = .bilingual
        alignment = .left
        verticalPosition = .center
        gap = .standard
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    var renderDimensions: (width: Int, height: Int) {
        let width = 1200
        return (width, max(150, Int((Double(width) / aspectRatioValue).rounded())))
    }
}

struct PiPLayoutMetrics {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let originalFont: CGFloat
    let translationFont: CGFloat
    let blockGap: CGFloat
    let lineSpacing: CGFloat
    let maxLines: Int

    static func make(renderSize: CGSize, ratio: PiPAspectRatio, mode: PiPDisplayMode,
                     fontScale: Double, translationFontScale: Double? = nil, gap: PiPCaptionGap) -> PiPLayoutMetrics {
        let height = max(120, renderSize.height)
        let ratioFactor: CGFloat = ratio == .standard ? 1.08 : (ratio == .ultraWide ? 0.86 : 1)
        let modeFactor: CGFloat = mode == .bilingual ? 0.82 : 1
        let base = min(48, max(22, height * 0.145 * ratioFactor * modeFactor))
        let scaled = base * CGFloat(min(3, max(0.3, fontScale)))
        let translatedScaled = base * CGFloat(min(3, max(0.3, translationFontScale ?? fontScale)))
        let vertical: CGFloat = ratio == .standard ? 24 : (ratio == .ultraWide ? 10 : 16)
        let resolvedGap = min(ratio == .ultraWide ? 10 : 16, gap.points)
        return PiPLayoutMetrics(
            horizontalPadding: max(24, renderSize.width * 0.03),
            verticalPadding: vertical,
            originalFont: scaled,
            translationFont: translatedScaled * 1.04,
            blockGap: resolvedGap,
            lineSpacing: max(2, scaled * 0.12),
            maxLines: ratio == .standard ? 4 : (ratio == .bar ? 3 : 2)
        )
    }
}

struct PiPInlinePreview: View {
    @ObservedObject var settings: PiPPresentationSettings

    private var horizontalAlignment: HorizontalAlignment {
        switch settings.alignment { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }
    private var frameAlignment: Alignment {
        switch settings.alignment { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }
    private var ratio: CGFloat {
        CGFloat(settings.aspectRatioValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.verticalPosition != .top { Spacer(minLength: 8) }
            VStack(alignment: horizontalAlignment, spacing: settings.gap.points / 2) {
                if settings.captionMode != .chineseOnly {
                    Text("The system is asymptotically stable.")
                        .foregroundStyle(.white)
                }
                if settings.captionMode != .originalOnly {
                    Text("這個系統是漸近穩定的。")
                        .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                }
            }
            .font(.system(size: 12 * DisplaySettings.shared.pipOriginalScale))
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            if settings.verticalPosition != .bottom { Spacer(minLength: 8) }
        }
        .padding(.horizontal, 14)
        .aspectRatio(ratio, contentMode: .fit)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(L10n.tr("子母字幕預覽", "PiP caption preview"))
    }
}
