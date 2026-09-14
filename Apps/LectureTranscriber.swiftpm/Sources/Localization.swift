import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case zhHant = "zh-Hant"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟隨系統 · Follow System"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }
}

public enum SupportedLanguage: String, CaseIterable, Identifiable {
    case zh = "zh"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case auto = "auto"
    case mixed = "mixed"

    public var id: String { rawValue }

    public var displayNameZh: String {
        switch self {
        case .zh: return "繁體中文"
        case .en: return "英文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .auto: return "自動偵測"
        case .mixed: return "中英夾雜"
        }
    }

    public var displayNameEn: String {
        switch self {
        case .zh: return "Traditional Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .auto: return "Auto Detect"
        case .mixed: return "Mixed Zh-En"
        }
    }
}

public enum EngineCapability {
    public static func isSupported(engine: String, language: String) -> (supported: Bool, detail: String) {
        switch engine {
        case "apple":
            switch language {
            case "zh", "en", "ja", "ko":
                return (true, "支援此語言的即時辨識")
            case "auto":
                return (false, "Apple 即時引擎需指定主要語言（中文或英文），不支援全自動")
            case "mixed", "mixed-en":
                return (true, "以指定的主要語言為主辨識")
            default:
                return (false, "目前不支援所選語言")
            }
        case "sensevoice":
            switch language {
            case "auto", "zh", "en", "ja", "ko", "mixed", "mixed-en":
                return (true, "支援中英日韓及多語言混說辨識")
            default:
                return (false, "SenseVoice 僅支援中、英、日、韓、粵語")
            }
        case "whisper":
            return (true, "Whisper 支援全球超過 99 種語言與混合辨識")
        default:
            return (true, "預設辨識")
        }
    }

    public static func isTranslationSupported(source: String, target: String = "zh-Hant") -> (supported: Bool, detail: String) {
        if source == target {
            return (false, "來源語言與目標語言相同")
        }
        if source == "en" || source == "ja" || source == "ko" {
            return (true, "Apple 裝置端離線翻譯已支援")
        }
        return (false, "暫無離線翻譯支援")
    }
}

@MainActor
public final class L10n: ObservableObject {
    public static let shared = L10n()

    @Published public var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "appLanguage"),
           let lang = AppLanguage(rawValue: saved) {
            self.appLanguage = lang
        } else {
            self.appLanguage = .system
        }
    }

    public var effectiveLocale: Locale {
        switch appLanguage {
        case .system:
            return Locale.autoupdatingCurrent
        case .zhHant:
            return Locale(identifier: "zh-Hant")
        case .en:
            return Locale(identifier: "en")
        }
    }

    public var isEnglish: Bool {
        switch appLanguage {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh"
            return preferred.hasPrefix("en")
        case .zhHant:
            return false
        case .en:
            return true
        }
    }

    public nonisolated static func tr(_ zh: String, _ en: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        if saved == "en" { return en }
        if saved == "zh-Hant" { return zh }
        let preferred = Locale.preferredLanguages.first ?? "zh"
        return preferred.hasPrefix("en") ? en : zh
    }
}
