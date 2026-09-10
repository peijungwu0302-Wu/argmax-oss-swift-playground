import Foundation
import SwiftUI
import UIKit

struct LectureUpdate: Codable, Equatable {
    var bundleIdentifier: String
    var version: String
    var build: Int
    var minimumOS: String
    var downloadURL: URL
    var notes: String
    func validate() throws {
        guard bundleIdentifier == "com.peijungwu0302.lecturetranscriber", build > 0,
              !version.isEmpty, downloadURL.scheme == "https",
              downloadURL.host == "raw.githubusercontent.com",
              downloadURL.path.hasPrefix("/peijungwu0302-Wu/argmax-oss-swift-playground/"),
              downloadURL.path.hasSuffix(".ipa") else { throw LectureError.message("更新來源或 App 識別不符。") }
    }
    func newer(than version: String, build: Int) -> Bool {
        let order = self.version.compare(version, options: .numeric)
        return order == .orderedDescending || (order == .orderedSame && self.build > build)
    }
}

@MainActor final class AppUpdates: ObservableObject {
    static let base = "https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/playground-compatible/Deliverables/"
    static let source = URL(string: base + "sidestore.json")!
    @Published private(set) var available: LectureUpdate?
    @Published private(set) var status = ""
    @Published private(set) var checking = false
    var current: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + "（" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + "）" }
    func check() async {
        guard !checking else { return }
        checking = true; available = nil; status = "正在檢查更新…"
        defer { checking = false }
        do {
            let request = URLRequest(url: URL(string: Self.base + "update.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 100_000 else { throw LectureError.message("更新資訊尚未發布或暫時無法取得。") }
            let update = try JSONDecoder().decode(LectureUpdate.self, from: data)
            try update.validate()
            guard UIDevice.current.systemVersion.compare(update.minimumOS, options: .numeric) != .orderedAscending else {
                status = "新版需要 iOS／iPadOS \(update.minimumOS)"; return
            }
            let installedVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
            let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            if update.newer(than: installedVersion, build: build) { available = update; status = "可更新至 \(update.version)" }
            else { status = "目前沒有較新的已發布版本" }
        } catch { status = error.localizedDescription }
    }
    static func sideStoreURL(action: String, target: URL) -> URL? {
        var parts = URLComponents(); parts.scheme = "sidestore"; parts.host = action
        parts.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        return parts.url
    }
    func openSideStore(source: Bool) {
        guard let target = source ? Self.source : available?.downloadURL,
              let url = Self.sideStoreURL(action: source ? "source" : "install", target: target) else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in self?.status = opened ? "請在 SideStore 完成確認、下載與簽署更新" : "無法開啟 SideStore，請確認已安裝並可正常使用。" }
        }
    }
}
