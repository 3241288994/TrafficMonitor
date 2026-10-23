import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case liveRate
    case todayTotal
    case monthTotal
    case quotaRemaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveRate: "实时上下行"
        case .todayTotal: "今日总量"
        case .monthTotal: "本月总量"
        case .quotaRemaining: "配额剩余"
        }
    }
}

enum PreferenceKey {
    static let accountingMode = "trafficAccountingMode"
    static let menuBarDisplayMode = "menuBarDisplayMode"
    static let monthlyQuotaBytes = "monthlyQuotaBytes"
    static let weeklyQuotaBytes = "weeklyQuotaBytes"
    static let dailyQuotaBytes = "dailyQuotaBytes"
    static let billingDay = "billingDay"
    static let quotaWarningPercent = "quotaWarningPercent"
    static let quotaAlertsEnabled = "quotaAlertsEnabled"
    static let networkQuotasJSON = "networkQuotasJSON"
    static let showDockIcon = "showDockIcon"
    static let showMenuBarIcon = "showMenuBarIcon"
}

enum NetworkQuotaPreferences {
    static func quotas() -> [String: Int64] {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.networkQuotasJSON),
              let value = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { return [:] }
        return value
    }

    static func setQuota(_ bytes: Int64, for network: String) {
        var values = quotas()
        if bytes > 0 { values[network] = bytes } else { values.removeValue(forKey: network) }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.networkQuotasJSON)
        }
    }
}
