import Foundation
import TrafficCore

struct LiveTrafficPoint: Identifiable, Sendable {
    let timestamp: Date
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double

    var id: Date { timestamp }
}

enum AppUsagePeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "本日"
        case .week: "本周"
        case .month: "本月"
        }
    }

    var subtitle: String { "\(title)按应用汇总" }
}

@MainActor
final class TrafficMonitorStore: ObservableObject {
    let qualityMonitor = NetworkQualityMonitor()
    @Published private(set) var snapshot = TrafficSnapshot(processes: [])
    @Published private(set) var accountingMode: TrafficAccountingMode
    @Published private(set) var livePoints: [LiveTrafficPoint] = []
    @Published private(set) var todayTotals = TrafficTotals()
    @Published private(set) var weekTotals = TrafficTotals()
    @Published private(set) var monthTotals = TrafficTotals()
    @Published private(set) var dailyTotals: [DailyTrafficTotal] = []
    @Published private(set) var topApps: [AppTrafficSummary] = []
    @Published private(set) var appPeriodApps: [AppTrafficSummary] = []
    @Published private(set) var appPeriodTotals = TrafficTotals()
    @Published private(set) var appUsagePeriod: AppUsagePeriod = .month
    @Published private(set) var historyPoints: [TrafficHistoryPoint] = []
    @Published private(set) var heatmapCells: [HourlyHeatmapCell] = []
    @Published private(set) var selectedRangeTotals = TrafficTotals()
    @Published private(set) var selectedRangeApps: [AppTrafficSummary] = []
    @Published private(set) var billingCycleTotals = TrafficTotals()
    @Published private(set) var currentNetworkTotals = TrafficTotals()
    @Published private(set) var currentNetworkName = "未知网络"
    @Published private(set) var knownNetworkNames: [String] = []
    @Published private(set) var uploadAnomalies: [UploadAnomaly] = []
    @Published private(set) var proxyRouting = ProxyRoutingSnapshot.unavailable("尚未读取", socketPath: "")
    @Published private(set) var isRefreshingProxyRouting = false
    /// 是否检测到本机 Clash/mihomo 可用；未安装或未运行时用于隐藏「代理分流」入口。
    @Published private(set) var isClashAvailable = false
    /// 代理页的历史统计（按范围+聚合）与目标排行。
    @Published private(set) var proxyHistoryPoints: [ProxyRoutingHistoryPoint] = []
    @Published private(set) var proxyHistoryTargets: [(target: String, isDirect: Bool, upload: Int64, download: Int64)] = []
    @Published private(set) var isRefreshingProxyHistory = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var isRefreshingHistory = false

    private let clashRoutingClient = ClashRoutingClient()
    private var proxyRoutingTask: Task<Void, Never>?
    /// 上一次各连接的累计字节，用于计算增量。
    private var lastConnectionBytes: [String: (up: Int64, down: Int64)] = [:]

    private let collector: TrafficCollector
    private let database: TrafficDatabase?
    private var isStarted = false
    private var lastHistoryRefresh = Date.distantPast
    private let networkDetector = NetworkProfileDetector()
    private var rawSnapshot = TrafficSnapshot(processes: [])

    init(collector: TrafficCollector = NettopCollector()) {
        self.collector = collector
        let savedMode = UserDefaults.standard.string(forKey: PreferenceKey.accountingMode)
        accountingMode = TrafficAccountingMode(rawValue: savedMode ?? "") ?? .application

        do {
            let supportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let databaseURL = supportURL
                .appendingPathComponent("TrafficMonitor", isDirectory: true)
                .appendingPathComponent("traffic.sqlite")
            database = try TrafficDatabase(url: databaseURL)
        } catch {
            database = nil
            historyErrorMessage = error.localizedDescription
        }
    }

    func start() {
        guard !isStarted else { return }

        do {
            try collector.start { [weak self] snapshot in
                Task { @MainActor in
                    self?.receive(snapshot)
                }
            }
            isStarted = true
            qualityMonitor.start()
            startProxyRoutingPolling()
            Task { await refreshHistory() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isStarted else { return }
        collector.stop()
        qualityMonitor.stop()
        proxyRoutingTask?.cancel()
        proxyRoutingTask = nil
        isStarted = false
    }

    /// 每 10 秒从 Clash 读取一次连接分流快照。
    private func startProxyRoutingPolling() {
        proxyRoutingTask?.cancel()
        proxyRoutingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshProxyRouting()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refreshProxyRouting() async {
        isRefreshingProxyRouting = true
        defer { isRefreshingProxyRouting = false }
        let client = clashRoutingClient
        let result = await Task.detached(priority: .utility) { () -> (ProxyRoutingSnapshot, [ClashRoutingClient.RawConnection]?) in
            (client.fetchSnapshot(), client.fetchRawConnections())
        }.value
        let (snapshot, rawConnections) = result
        proxyRouting = snapshot
        isClashAvailable = snapshot.isAvailable

        // 记录增量到历史库。
        if let rawConnections, let database {
            let records = Self.incrementRecords(from: rawConnections, previous: lastConnectionBytes)
            lastConnectionBytes = Dictionary(
                uniqueKeysWithValues: rawConnections.map { ($0.id, ($0.upload, $0.download)) }
            )
            if !records.isEmpty {
                let now = Date()
                try? await database.recordProxyRouting(records, at: now)
            }
        } else {
            lastConnectionBytes.removeAll()
        }
    }

    /// 用当前连接累计字节减去上次快照，得到本区间增量，按目标+是否直连聚合。
    private static func incrementRecords(
        from connections: [ClashRoutingClient.RawConnection],
        previous: [String: (up: Int64, down: Int64)]
    ) -> [ProxyRoutingRecord] {
        var aggregated: [String: ProxyRoutingRecord] = [:]
        for conn in connections {
            let prev = previous[conn.id] ?? (0, 0)
            let upDelta = max(0, conn.upload - prev.up)
            let downDelta = max(0, conn.download - prev.down)
            guard upDelta > 0 || downDelta > 0 else { continue }
            let key = "\(conn.target)|\(conn.isDirect)"
            if let existing = aggregated[key] {
                aggregated[key] = ProxyRoutingRecord(
                    target: conn.target,
                    isDirect: conn.isDirect,
                    uploadBytes: existing.uploadBytes + upDelta,
                    downloadBytes: existing.downloadBytes + downDelta
                )
            } else {
                aggregated[key] = ProxyRoutingRecord(
                    target: conn.target,
                    isDirect: conn.isDirect,
                    uploadBytes: upDelta,
                    downloadBytes: downDelta
                )
            }
        }
        return Array(aggregated.values)
    }

    /// 加载代理页历史统计（按范围 + 聚合）。
    func loadProxyHistory(from start: Date, to end: Date, aggregation: TrafficAggregation) async {
        guard let database else { return }
        isRefreshingProxyHistory = true
        defer { isRefreshingProxyHistory = false }
        do {
            async let points = database.proxyRoutingHistory(from: start, to: end, aggregation: aggregation)
            async let targets = database.proxyRoutingTargets(from: start, to: end)
            proxyHistoryPoints = try await points
            proxyHistoryTargets = try await targets
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func refreshHistory() async {
        guard let database else { return }
        isRefreshingHistory = true
        defer { isRefreshingHistory = false }

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfDay
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfDay

        do {
            let mode = accountingMode
            let today = try await database.totals(from: startOfDay, to: now, accountingMode: mode)
            let week = try await database.totals(from: startOfWeek, to: now, accountingMode: mode)
            let month = try await database.totals(from: startOfMonth, to: now, accountingMode: mode)
            let days = try await database.dailyTotals(days: 7, endingAt: now, accountingMode: mode)
            let apps = try await database.topApps(from: startOfMonth, to: now, limit: 100, accountingMode: mode)
            let selectedAppStart = appPeriodStart(
                for: appUsagePeriod,
                now: now,
                calendar: calendar
            )
            let selectedApps: [AppTrafficSummary]
            let selectedTotals: TrafficTotals
            if appUsagePeriod == .month {
                selectedApps = apps
                selectedTotals = month
            } else {
                selectedApps = try await database.topApps(
                    from: selectedAppStart,
                    to: now,
                    limit: 500,
                    accountingMode: mode
                )
                selectedTotals = try await database.totals(
                    from: selectedAppStart,
                    to: now,
                    accountingMode: mode
                )
            }
            let billingStart = billingCycleStart(now: now, calendar: calendar)
            let networkName = networkDetector.currentName()
            let billing = try await database.totals(from: billingStart, to: now, accountingMode: mode)
            let network = try await database.totals(
                from: billingStart,
                to: now,
                networkKey: networkName,
                accountingMode: mode
            )
            let networks = try await database.networkKeys()
            let anomalies = try await database.uploadAnomalies(now: now)

            todayTotals = today
            weekTotals = week
            monthTotals = month
            dailyTotals = days
            topApps = apps
            appPeriodApps = selectedApps
            appPeriodTotals = selectedTotals
            billingCycleTotals = billing
            currentNetworkTotals = network
            currentNetworkName = networkName
            knownNetworkNames = networks
            uploadAnomalies = anomalies
            QuotaNotifications.evaluate(
                today: today.totalBytes,
                week: week.totalBytes,
                billingCycle: billing.totalBytes,
                network: network.totalBytes,
                networkName: networkName
            )
            historyErrorMessage = nil
            lastHistoryRefresh = now
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func resetHistory() async {
        guard let database else { return }
        do {
            try await database.reset()
            await refreshHistory()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func requestWiFiNameAccess() {
        networkDetector.requestSSIDAccess()
    }

    func setAccountingMode(_ mode: TrafficAccountingMode) {
        guard accountingMode != mode else { return }
        accountingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKey.accountingMode)
        snapshot = rawSnapshot.applying(mode)
        Task { await refreshHistory() }
    }

    func setAppUsagePeriod(_ period: AppUsagePeriod) async {
        guard appUsagePeriod != period else { return }
        appUsagePeriod = period
        await refreshAppPeriod()
    }

    func refreshAppPeriod() async {
        guard let database else { return }
        let calendar = Calendar.current
        let now = Date()
        let start = appPeriodStart(for: appUsagePeriod, now: now, calendar: calendar)
        do {
            async let apps = database.topApps(
                from: start,
                to: now,
                limit: 500,
                accountingMode: accountingMode
            )
            async let totals = database.totals(
                from: start,
                to: now,
                accountingMode: accountingMode
            )
            appPeriodApps = try await apps
            appPeriodTotals = try await totals
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func loadHistory(
        from start: Date,
        to end: Date,
        aggregation: TrafficAggregation
    ) async {
        guard let database else { return }
        isRefreshingHistory = true
        defer { isRefreshingHistory = false }
        do {
            let mode = accountingMode
            async let totals = database.totals(from: start, to: end, accountingMode: mode)
            async let points = database.history(from: start, to: end, aggregation: aggregation, accountingMode: mode)
            async let heatmap = database.hourlyHeatmap(from: start, to: end, accountingMode: mode)
            async let apps = database.topApps(from: start, to: end, limit: 500, accountingMode: mode)
            selectedRangeTotals = try await totals
            historyPoints = try await points
            heatmapCells = try await heatmap
            selectedRangeApps = try await apps
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func exportData(
        from start: Date,
        to end: Date,
        aggregation: TrafficAggregation,
        format: TrafficExportFormat
    ) async throws -> Data {
        guard let database else {
            throw TrafficExportError.databaseUnavailable
        }
        let rows = try await database.exportRows(
            from: start,
            to: end,
            aggregation: aggregation,
            accountingMode: accountingMode
        )
        return try TrafficExporter.data(for: rows, format: format)
    }

    private func receive(_ snapshot: TrafficSnapshot) {
        rawSnapshot = snapshot
        self.snapshot = snapshot.applying(accountingMode)
        errorMessage = nil

        livePoints.append(
            LiveTrafficPoint(
                timestamp: self.snapshot.timestamp,
                receivedBytesPerSecond: self.snapshot.totalReceivedBytesPerSecond,
                sentBytesPerSecond: self.snapshot.totalSentBytesPerSecond
            )
        )
        if livePoints.count > 120 {
            livePoints.removeFirst(livePoints.count - 120)
        }

        guard let database else { return }
        Task {
            do {
                let networkName = networkDetector.currentName()
                try await database.record(snapshot, networkKey: networkName)
                if Date().timeIntervalSince(lastHistoryRefresh) >= 10 {
                    await refreshHistory()
                }
            } catch {
                historyErrorMessage = error.localizedDescription
            }
        }
    }

    private func billingCycleStart(now: Date, calendar: Calendar) -> Date {
        let configured = UserDefaults.standard.integer(forKey: PreferenceKey.billingDay)
        let billingDay = min(max(configured == 0 ? 1 : configured, 1), 28)
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = billingDay
        components.hour = 0
        components.minute = 0
        components.second = 0
        var start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
        if start > now {
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        return start
    }

    private func appPeriodStart(
        for period: AppUsagePeriod,
        now: Date,
        calendar: Calendar
    ) -> Date {
        switch period {
        case .day:
            calendar.startOfDay(for: now)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .month:
            calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        }
    }
}

enum TrafficExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum TrafficExportError: LocalizedError {
    case databaseUnavailable
    var errorDescription: String? { "历史数据库不可用" }
}

enum TrafficExporter {
    static func data(
        for rows: [TrafficExportRow],
        format: TrafficExportFormat
    ) throws -> Data {
        switch format {
        case .csv:
            let isoFormatter = ISO8601DateFormatter()
            var lines = ["time,app_key,app_name,network,layer,download_bytes,upload_bytes,total_bytes"]
            lines += rows.map { row in
                [
                    csv(isoFormatter.string(from: row.start)),
                    csv(row.appKey),
                    csv(row.appName),
                    csv(row.networkKey),
                    row.isProxyTransport ? "proxy" : "application",
                    String(row.receivedBytes),
                    String(row.sentBytes),
                    String(row.totalBytes)
                ].joined(separator: ",")
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .json:
            let isoFormatter = ISO8601DateFormatter()
            let objects: [[String: Any]] = rows.map { row in
                [
                    "time": isoFormatter.string(from: row.start),
                    "app_key": row.appKey,
                    "app_name": row.appName,
                    "network": row.networkKey,
                    "layer": row.isProxyTransport ? "proxy" : "application",
                    "download_bytes": row.receivedBytes,
                    "upload_bytes": row.sentBytes,
                    "total_bytes": row.totalBytes
                ]
            }
            return try JSONSerialization.data(
                withJSONObject: objects,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }
    }

    private static func csv(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
