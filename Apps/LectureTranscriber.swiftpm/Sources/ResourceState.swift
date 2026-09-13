import Foundation

public enum ResourceState: Equatable, Sendable {
    case notDownloaded
    case preparing(progress: Double?)
    case downloading(bytesReceived: Int64, totalBytes: Int64?, progress: Double)
    case extracting(progress: Double)
    case compiling(progress: Double)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var progressValue: Double? {
        switch self {
        case .preparing(let progress): return progress
        case .downloading(_, _, let progress):
            return progress
        case .extracting(let progress):
            return progress
        case .compiling(let progress):
            return progress
        case .ready:
            return 1.0
        case .notDownloaded, .failed:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .preparing(let progress):
            if let progress { return "正在準備系統資源（\(Int((progress * 100).rounded()))%）" }
            return "正在準備系統資源…"
        case .notDownloaded:
            return "尚未下載"
        case .downloading(let received, let total, let progress):
            let receivedMB = Double(received) / 1_048_576.0
            if let total, total > 0 {
                let totalMB = Double(total) / 1_048_576.0
                let percent = min(100, max(0, Int((progress * 100).rounded())))
                return String(format: "下載中：%.1f MB / %.1f MB (%d%%)", receivedMB, totalMB, percent)
            } else {
                return String(format: "下載中：已接收 %.1f MB", receivedMB)
            }
        case .extracting(let progress):
            let percent = min(100, max(0, Int((progress * 100).rounded())))
            return "正在解壓縮 (\(percent)%)"
        case .compiling(let progress):
            let percent = min(100, max(0, Int((progress * 100).rounded())))
            return "正在編譯模型 (\(percent)%)"
        case .ready:
            return "已就緒"
        case .failed(let message):
            return "失敗：\(message)"
        }
    }

    public func localizedDescription(in language: String) -> String {
        let isEn = language.hasPrefix("en")
        switch self {
        case .preparing(let progress):
            if let progress {
                return isEn ? "Preparing system resource (\(Int((progress * 100).rounded()))%)" : "正在準備系統資源（\(Int((progress * 100).rounded()))%）"
            }
            return isEn ? "Preparing system resource…" : "正在準備系統資源…"
        case .notDownloaded:
            return isEn ? "Not Downloaded" : "尚未下載"
        case .downloading(let received, let total, let progress):
            let receivedMB = Double(received) / 1_048_576.0
            if let total, total > 0 {
                let totalMB = Double(total) / 1_048_576.0
                let percent = min(100, max(0, Int((progress * 100).rounded())))
                return isEn
                    ? String(format: "Downloading: %.1f MB / %.1f MB (%d%%)", receivedMB, totalMB, percent)
                    : String(format: "下載中：%.1f MB / %.1f MB (%d%%)", receivedMB, totalMB, percent)
            } else {
                return isEn
                    ? String(format: "Downloading: %.1f MB received", receivedMB)
                    : String(format: "下載中：已接收 %.1f MB", receivedMB)
            }
        case .extracting(let progress):
            let percent = min(100, max(0, Int((progress * 100).rounded())))
            return isEn ? "Extracting (\(percent)%)" : "正在解壓縮 (\(percent)%)"
        case .compiling(let progress):
            let percent = min(100, max(0, Int((progress * 100).rounded())))
            return isEn ? "Compiling Model (\(percent)%)" : "正在編譯模型 (\(percent)%)"
        case .ready:
            return isEn ? "Ready" : "已就緒"
        case .failed(let message):
            return isEn ? "Failed: \(message)" : "失敗：\(message)"
        }
    }
}
