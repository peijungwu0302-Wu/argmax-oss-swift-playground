import Foundation
import SwiftUI
import Combine

/// Model representing the embedded provisioning profile used for sideloaded app signing.
public struct SigningProfile: Equatable, Sendable {
    public var uuid: String?
    public var name: String?
    public var teamName: String?
    public var creationDate: Date?
    public var expirationDate: Date
    public var isDevelopment: Bool

    public init(uuid: String? = nil,
                name: String? = nil,
                teamName: String? = nil,
                creationDate: Date? = nil,
                expirationDate: Date,
                isDevelopment: Bool = false) {
        self.uuid = uuid
        self.name = name
        self.teamName = teamName
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.isDevelopment = isDevelopment
    }

    /// Locate and parse the installed embedded.mobileprovision in the main bundle.
    public static func load(from bundle: Bundle = .main) -> SigningProfile? {
        // Look for embedded.mobileprovision in bundle resource or direct app root
        let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") ??
                  bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    /// Extract and decode the XML PropertyList payload from the PKCS#7 signed container.
    public static func parse(data: Data) -> SigningProfile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let expirationDate = plist["ExpirationDate"] as? Date else {
            return nil
        }
        let uuid = plist["UUID"] as? String
        let name = plist["Name"] as? String
        let teamName = plist["TeamName"] as? String
        let creationDate = plist["CreationDate"] as? Date
        let isDev = (plist["Entitlements"] as? [String: Any])?["get-task-allow"] as? Bool ?? false

        return SigningProfile(
            uuid: uuid,
            name: name,
            teamName: teamName,
            creationDate: creationDate,
            expirationDate: expirationDate,
            isDevelopment: isDev
        )
    }
}

/// Verification status for SideStore Self Refresh.
public enum SelfRefreshStatus: String, Codable, Equatable, Sendable {
    case verified = "VERIFIED"
    case notRenewed = "NOT_RENEWED"
    case pending = "PENDING"
    case none = "NONE"

    public var displayText: String {
        switch self {
        case .verified: return "VERIFIED（簽署期限已成功展延）"
        case .notRenewed: return "NOT_RENEWED（有效期限未展延）"
        case .pending: return "PENDING（等待刷新後重啟核對）"
        case .none: return "NONE"
        }
    }
}

/// Diagnostic comparison record between pre-refresh and post-refresh profiles.
public struct SelfRefreshDiagnostics: Equatable, Sendable {
    public var beforeExpirationDate: Date?
    public var afterExpirationDate: Date?
    public var beforeCreationDate: Date?
    public var afterCreationDate: Date?
    public var beforeProfileUUID: String?
    public var afterProfileUUID: String?

    public init(beforeExpirationDate: Date? = nil,
                afterExpirationDate: Date? = nil,
                beforeCreationDate: Date? = nil,
                afterCreationDate: Date? = nil,
                beforeProfileUUID: String? = nil,
                afterProfileUUID: String? = nil) {
        self.beforeExpirationDate = beforeExpirationDate
        self.afterExpirationDate = afterExpirationDate
        self.beforeCreationDate = beforeCreationDate
        self.afterCreationDate = afterCreationDate
        self.beforeProfileUUID = beforeProfileUUID
        self.afterProfileUUID = afterProfileUUID
    }

    /// Expiration delta in seconds (preserves full second precision).
    public var expirationDeltaSeconds: Double? {
        guard let before = beforeExpirationDate, let after = afterExpirationDate else { return nil }
        return after.timeIntervalSince(before)
    }

    /// Primary verification: afterExpirationDate > beforeExpirationDate
    public var isExpirationExtended: Bool {
        guard let before = beforeExpirationDate, let after = afterExpirationDate else { return false }
        return after > before
    }

    public var isUUIDChanged: Bool? {
        guard let b = beforeProfileUUID, let a = afterProfileUUID else { return nil }
        return b != a
    }

    public var isCreationDateChanged: Bool? {
        guard let b = beforeCreationDate, let a = afterCreationDate else { return nil }
        return b != a
    }

    public var status: SelfRefreshStatus {
        guard beforeExpirationDate != nil, afterExpirationDate != nil else { return .none }
        return isExpirationExtended ? .verified : .notRenewed
    }
}

/// Date and time formatting utilities with second-level precision.
public enum SigningTimeFormatter {
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_Hant_TW")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return df
    }()

    public static func formatDateTime(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// Formats remaining duration into second-level precision, e.g. "6 天 23:47:18" or "23:47:18".
    /// Never rounds to day, hour, or minute.
    public static func formatRemaining(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total <= 0 {
            return "已到期 00:00:00"
        }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if days > 0 {
            return String(format: "%d 天 %02d:%02d:%02d", days, hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
    }

    public static func formatDelta(seconds: Double) -> String {
        let sign = seconds >= 0 ? "+" : ""
        return String(format: "%@%.0f 秒", sign, seconds)
    }
}

/// Observable manager responsible for managing signing expiration countdown and verification.
/// Parses the installed profile ONCE and drives UI updates through a 1-second timer.
@MainActor
public final class SigningExpirationManager: ObservableObject {
    public static let shared = SigningExpirationManager()

    // UserDefaults keys for Self Refresh verification persistence
    private static let keyBeforeUUID = "Signing_BeforeProfileUUID"
    private static let keyBeforeCreationDate = "Signing_BeforeCreationDate"
    private static let keyBeforeExpirationDate = "Signing_BeforeExpirationDate"
    private static let keyLastVerifiedStatus = "Signing_LastVerifiedStatus"
    private static let keyLastVerifiedDiagnostics = "Signing_LastVerifiedDiagnostics"

    @Published public private(set) var profile: SigningProfile?
    @Published public private(set) var remainingString: String = ""
    @Published public private(set) var expirationString: String = ""
    @Published public private(set) var isExpired: Bool = false
    @Published public private(set) var diagnostics: SelfRefreshDiagnostics? = nil
    @Published public private(set) var selfRefreshStatus: SelfRefreshStatus = .none

    private var countdownTimer: Timer?
    private var isParsed: Bool = false

    public init() {
        loadProfileOnce()
    }

    /// Parses the installed profile ONCE.
    public func loadProfileOnce(bundle: Bundle = .main) {
        guard !isParsed else { return }
        isParsed = true
        if let p = SigningProfile.load(from: bundle) {
            self.profile = p
            self.expirationString = SigningTimeFormatter.formatDateTime(p.expirationDate)
            updateRemaining()
            startCountdownTimer()
            checkPendingVerification(currentProfile: p)
        } else {
            // Development or Simulator without mobileprovision
            self.remainingString = "開發／模擬器環境（無 mobileprovision）"
            self.expirationString = "未受限"
        }
    }

    /// Injects a custom profile for testing or preview purposes.
    public func setProfileForTesting(_ profile: SigningProfile) {
        self.profile = profile
        self.expirationString = SigningTimeFormatter.formatDateTime(profile.expirationDate)
        updateRemaining()
        startCountdownTimer()
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRemaining()
            }
        }
    }

    /// Updates the remaining countdown without re-parsing the file.
    private func updateRemaining() {
        guard let p = profile else { return }
        let now = Date()
        let diff = p.expirationDate.timeIntervalSince(now)
        if diff <= 0 {
            self.isExpired = true
            self.remainingString = "已過期 00:00:00"
        } else {
            self.isExpired = false
            self.remainingString = SigningTimeFormatter.formatRemaining(seconds: diff)
        }
    }

    // MARK: - Self Refresh Verification

    /// Call before SideStore self refresh / reinstall to capture baseline profile metadata.
    public func recordBeforeRefresh(userDefaults: UserDefaults = .standard) {
        guard let p = profile else { return }
        userDefaults.set(p.uuid, forKey: Self.keyBeforeUUID)
        if let creation = p.creationDate {
            userDefaults.set(creation.timeIntervalSince1970, forKey: Self.keyBeforeCreationDate)
        }
        userDefaults.set(p.expirationDate.timeIntervalSince1970, forKey: Self.keyBeforeExpirationDate)
        userDefaults.set(SelfRefreshStatus.pending.rawValue, forKey: Self.keyLastVerifiedStatus)
        self.selfRefreshStatus = .pending
    }

    /// Verifies whether the newly active profile has an extended expiration timestamp.
    /// Primary verification condition: afterExpirationDate > beforeExpirationDate
    /// If expiration remains exactly unchanged, do NOT claim renewal.
    public func checkPendingVerification(currentProfile: SigningProfile, userDefaults: UserDefaults = .standard) {
        let beforeExpTimestamp = userDefaults.double(forKey: Self.keyBeforeExpirationDate)
        guard beforeExpTimestamp > 0 else { return }

        let beforeExp = Date(timeIntervalSince1970: beforeExpTimestamp)
        let beforeCreationTimestamp = userDefaults.double(forKey: Self.keyBeforeCreationDate)
        let beforeCreation = beforeCreationTimestamp > 0 ? Date(timeIntervalSince1970: beforeCreationTimestamp) : nil
        let beforeUUID = userDefaults.string(forKey: Self.keyBeforeUUID)

        var diag = SelfRefreshDiagnostics(
            beforeExpirationDate: beforeExp,
            afterExpirationDate: currentProfile.expirationDate,
            beforeCreationDate: beforeCreation,
            afterCreationDate: currentProfile.creationDate,
            beforeProfileUUID: beforeUUID,
            afterProfileUUID: currentProfile.uuid
        )

        self.diagnostics = diag
        self.selfRefreshStatus = diag.status

        // Persist verified status
        userDefaults.set(diag.status.rawValue, forKey: Self.keyLastVerifiedStatus)

        // Clear before markers so it does not falsely trigger on subsequent normal launches
        userDefaults.removeObject(forKey: Self.keyBeforeExpirationDate)
        userDefaults.removeObject(forKey: Self.keyBeforeCreationDate)
        userDefaults.removeObject(forKey: Self.keyBeforeUUID)
    }

    /// Directly verify two profiles for testing or diagnostics.
    public static func verifyRefresh(before: SigningProfile, after: SigningProfile) -> SelfRefreshDiagnostics {
        SelfRefreshDiagnostics(
            beforeExpirationDate: before.expirationDate,
            afterExpirationDate: after.expirationDate,
            beforeCreationDate: before.creationDate,
            afterCreationDate: after.creationDate,
            beforeProfileUUID: before.uuid,
            afterProfileUUID: after.uuid
        )
    }
}

public struct SigningExpirationSection: View {
    @StateObject private var manager = SigningExpirationManager.shared
    @State private var showDiagnostics = false

    public init() {}

    public var body: some View {
        Section("側載簽署有效期限") {
            HStack {
                Text("剩餘有效時間")
                Spacer()
                Text(manager.remainingString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(manager.isExpired ? .red : .primary)
            }
            HStack {
                Text("到期時間")
                Spacer()
                Text(manager.expirationString)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let profile = manager.profile {
                if let name = profile.name {
                    HStack {
                        Text("簽署描述檔")
                        Spacer()
                        Text(name).font(.caption).foregroundColor(.secondary)
                    }
                }
                if let team = profile.teamName {
                    HStack {
                        Text("開發者團隊")
                        Spacer()
                        Text(team).font(.caption).foregroundColor(.secondary)
                    }
                }
                Button("記錄刷新前基準（Self Refresh 驗證）") {
                    manager.recordBeforeRefresh()
                }
            }
            if manager.diagnostics != nil || manager.selfRefreshStatus != .none {
                Button("查看 Self Refresh 診斷報告") {
                    showDiagnostics = true
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            SigningDiagnosticsSheet(diagnostics: manager.diagnostics)
        }
    }
}

public struct SigningDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var diagnostics: SelfRefreshDiagnostics?

    public init(diagnostics: SelfRefreshDiagnostics?) {
        self.diagnostics = diagnostics
    }

    public var body: some View {
        NavigationStack {
            List {
                if let diag = diagnostics {
                    Section("Self Refresh 診斷結果") {
                        HStack {
                            Text("Self Refresh")
                            Spacer()
                            Text(diag.status == .verified ? "VERIFIED" : (diag.status == .notRenewed ? "NOT RENEWED" : "PENDING"))
                                .bold()
                                .foregroundColor(diag.status == .verified ? .green : .red)
                        }
                        if let delta = diag.expirationDeltaSeconds {
                            HStack {
                                Text("Expiration Delta")
                                Spacer()
                                Text(SigningTimeFormatter.formatDelta(seconds: delta))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(delta > 0 ? .green : .red)
                            }
                        }
                    }
                    Section("到期時間比對（精確至秒）") {
                        if let before = diag.beforeExpirationDate {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Before Expiration:").font(.caption).foregroundColor(.secondary)
                                Text(SigningTimeFormatter.formatDateTime(before))
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        if let after = diag.afterExpirationDate {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("After Expiration:").font(.caption).foregroundColor(.secondary)
                                Text(SigningTimeFormatter.formatDateTime(after))
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    Section("描述檔異動指標") {
                        HStack {
                            Text("Profile UUID Changed:")
                            Spacer()
                            Text(diag.isUUIDChanged == true ? "Yes" : (diag.isUUIDChanged == false ? "No" : "N/A"))
                        }
                        HStack {
                            Text("CreationDate Changed:")
                            Spacer()
                            Text(diag.isCreationDateChanged == true ? "Yes" : (diag.isCreationDateChanged == false ? "No" : "N/A"))
                        }
                    }
                } else {
                    Text("尚未記錄 Self Refresh 前後數據。在刷新前點擊「記錄刷新前基準」即可在刷新後自動核對。")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Developer Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}