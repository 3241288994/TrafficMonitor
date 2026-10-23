import Foundation
import SQLite3

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public enum TrafficDatabaseError: LocalizedError {
    case openFailed(String)
    case sqlite(message: String, statement: String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "无法打开流量数据库：\(message)"
        case let .sqlite(message, statement):
            return "数据库操作失败：\(message)（\(statement)）"
        }
    }
}

public actor TrafficDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let connection: SQLiteConnection
    private let calendar: Calendar

    public init(url: URL, calendar: Calendar = .current) throws {
        self.calendar = calendar

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let database { sqlite3_close(database) }
            throw TrafficDatabaseError.openFailed(message)
        }
        guard let database else {
            throw TrafficDatabaseError.openFailed("SQLite 未返回数据库句柄")
        }

        connection = SQLiteConnection(pointer: database)
        sqlite3_busy_timeout(database, 2_000)
        try Self.execute("PRAGMA journal_mode = WAL", on: database)
        try Self.execute("PRAGMA synchronous = NORMAL", on: database)
        try Self.execute(
            """
            CREATE TABLE IF NOT EXISTS traffic_buckets (
                bucket_start INTEGER NOT NULL,
                app_key TEXT NOT NULL,
                app_name TEXT NOT NULL,
                network_key TEXT NOT NULL DEFAULT '',
                traffic_layer INTEGER NOT NULL DEFAULT 0,
                received_bytes INTEGER NOT NULL DEFAULT 0,
                sent_bytes INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bucket_start, app_key, network_key, traffic_layer)
            )
            """,
            on: database
        )
        try Self.migrateNetworkKeyIfNeeded(on: database)
        try Self.migrateTrafficLayerIfNeeded(on: database)
        try Self.execute(
            "CREATE INDEX IF NOT EXISTS idx_traffic_buckets_time ON traffic_buckets(bucket_start)",
            on: database
        )
        try Self.execute(
            """
            CREATE TABLE IF NOT EXISTS proxy_routing_buckets (
                bucket_start INTEGER NOT NULL,
                target TEXT NOT NULL,
                is_direct INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bucket_start, target, is_direct)
            )
            """,
            on: database
        )
        try Self.execute(
            "CREATE INDEX IF NOT EXISTS idx_proxy_routing_time ON proxy_routing_buckets(bucket_start)",
            on: database
        )
    }

    public func record(_ snapshot: TrafficSnapshot, networkKey: String = "") throws {
        let activeProcesses = snapshot.processes.filter {
            $0.receivedBytes > 0 || $0.sentBytes > 0
        }
        guard !activeProcesses.isEmpty else { return }

        let bucketStart = Int64(snapshot.timestamp.timeIntervalSince1970 / 60) * 60
        let sql =
            """
            INSERT INTO traffic_buckets
                (bucket_start, app_key, app_name, network_key, traffic_layer, received_bytes, sent_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_start, app_key, network_key, traffic_layer) DO UPDATE SET
                app_name = excluded.app_name,
                received_bytes = received_bytes + excluded.received_bytes,
                sent_bytes = sent_bytes + excluded.sent_bytes
            """

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            for process in activeProcesses {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                let appName = process.processName
                let appKey = appName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )

                sqlite3_bind_int64(statement, 1, bucketStart)
                sqlite3_bind_text(statement, 2, appKey, -1, Self.transient)
                sqlite3_bind_text(statement, 3, appName, -1, Self.transient)
                sqlite3_bind_text(statement, 4, networkKey, -1, Self.transient)
                sqlite3_bind_int(statement, 5, process.isProxyTransport ? 1 : 0)
                sqlite3_bind_int64(statement, 6, process.receivedBytes)
                sqlite3_bind_int64(statement, 7, process.sentBytes)

                try step(statement, sql: sql)
            }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func totals(
        from start: Date,
        to end: Date = Date(),
        networkKey: String? = nil,
        accountingMode: TrafficAccountingMode = .application
    ) throws -> TrafficTotals {
        let sql =
            """
            SELECT COALESCE(SUM(received_bytes), 0), COALESCE(SUM(sent_bytes), 0)
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
              AND (? IS NULL OR network_key = ?)
              \(accountingClause(accountingMode))
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))
        bindOptionalText(networkKey, statement: statement, index: 3)
        bindOptionalText(networkKey, statement: statement, index: 4)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(statement: sql)
        }
        return TrafficTotals(
            receivedBytes: sqlite3_column_int64(statement, 0),
            sentBytes: sqlite3_column_int64(statement, 1)
        )
    }

    public func topApps(
        from start: Date,
        to end: Date = Date(),
        limit: Int = 12,
        networkKey: String? = nil,
        accountingMode: TrafficAccountingMode = .application
    ) throws -> [AppTrafficSummary] {
        let sql =
            """
            SELECT app_key, MAX(app_name), SUM(received_bytes), SUM(sent_bytes)
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
              AND (? IS NULL OR network_key = ?)
              \(accountingClause(accountingMode))
              AND app_key NOT IN (
                  'mdnsresponder', 'captiveagent', 'configd', 'airportd',
                  'netbiosd', 'rapportd', 'trustd', 'apsd', 'symptomsd', 'syslogd'
              )
            GROUP BY app_key
            ORDER BY SUM(received_bytes + sent_bytes) DESC
            LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))
        bindOptionalText(networkKey, statement: statement, index: 3)
        bindOptionalText(networkKey, statement: statement, index: 4)
        sqlite3_bind_int(statement, 5, Int32(max(1, limit)))

        var results: [AppTrafficSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                AppTrafficSummary(
                    appKey: string(statement, column: 0),
                    appName: string(statement, column: 1),
                    receivedBytes: sqlite3_column_int64(statement, 2),
                    sentBytes: sqlite3_column_int64(statement, 3)
                )
            )
        }
        return results
    }

    public func dailyTotals(
        days: Int,
        endingAt end: Date = Date(),
        accountingMode: TrafficAccountingMode = .application
    ) throws -> [DailyTrafficTotal] {
        let dayCount = max(1, days)
        let endDay = calendar.startOfDay(for: end)
        guard let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: endDay),
              let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            return []
        }

        let sql =
            """
            SELECT bucket_start, received_bytes, sent_bytes
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
              \(accountingClause(accountingMode))
            ORDER BY bucket_start ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(firstDay.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(exclusiveEnd.timeIntervalSince1970))

        var totalsByDay: [Date: TrafficTotals] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            let day = calendar.startOfDay(for: timestamp)
            let existing = totalsByDay[day] ?? TrafficTotals()
            totalsByDay[day] = TrafficTotals(
                receivedBytes: existing.receivedBytes + sqlite3_column_int64(statement, 1),
                sentBytes: existing.sentBytes + sqlite3_column_int64(statement, 2)
            )
        }

        return (0..<dayCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            let totals = totalsByDay[day] ?? TrafficTotals()
            return DailyTrafficTotal(
                day: day,
                receivedBytes: totals.receivedBytes,
                sentBytes: totals.sentBytes
            )
        }
    }

    public func history(
        from start: Date,
        to end: Date,
        aggregation: TrafficAggregation,
        networkKey: String? = nil,
        accountingMode: TrafficAccountingMode = .application
    ) throws -> [TrafficHistoryPoint] {
        let sql =
            """
            SELECT bucket_start, received_bytes, sent_bytes
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
              AND (? IS NULL OR network_key = ?)
              \(accountingClause(accountingMode))
            ORDER BY bucket_start ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))
        bindOptionalText(networkKey, statement: statement, index: 3)
        bindOptionalText(networkKey, statement: statement, index: 4)

        var totals: [Date: TrafficTotals] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            let grouped = aggregationStart(for: timestamp, aggregation: aggregation)
            let current = totals[grouped] ?? TrafficTotals()
            totals[grouped] = TrafficTotals(
                receivedBytes: current.receivedBytes + sqlite3_column_int64(statement, 1),
                sentBytes: current.sentBytes + sqlite3_column_int64(statement, 2)
            )
        }
        return totals.keys.sorted().map { date in
            let value = totals[date] ?? TrafficTotals()
            return TrafficHistoryPoint(
                start: date,
                receivedBytes: value.receivedBytes,
                sentBytes: value.sentBytes
            )
        }
    }

    public func hourlyHeatmap(
        from start: Date,
        to end: Date,
        accountingMode: TrafficAccountingMode = .application
    ) throws -> [HourlyHeatmapCell] {
        let points = try history(from: start, to: end, aggregation: .hour, accountingMode: accountingMode)
        var totals: [String: TrafficTotals] = [:]
        for point in points {
            let components = calendar.dateComponents([.weekday, .hour], from: point.start)
            let weekday = components.weekday ?? 1
            let hour = components.hour ?? 0
            let key = "\(weekday)-\(hour)"
            let current = totals[key] ?? TrafficTotals()
            totals[key] = TrafficTotals(
                receivedBytes: current.receivedBytes + point.receivedBytes,
                sentBytes: current.sentBytes + point.sentBytes
            )
        }
        return (1...7).flatMap { weekday in
            (0..<24).map { hour in
                let value = totals["\(weekday)-\(hour)"] ?? TrafficTotals()
                return HourlyHeatmapCell(
                    weekday: weekday,
                    hour: hour,
                    receivedBytes: value.receivedBytes,
                    sentBytes: value.sentBytes
                )
            }
        }
    }

    public func exportRows(
        from start: Date,
        to end: Date,
        aggregation: TrafficAggregation,
        accountingMode: TrafficAccountingMode = .application
    ) throws -> [TrafficExportRow] {
        let sql =
            """
            SELECT bucket_start, app_key, app_name, network_key, traffic_layer, received_bytes, sent_bytes
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
              \(accountingClause(accountingMode))
            ORDER BY bucket_start ASC, app_name COLLATE NOCASE ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        struct ExportKey: Hashable {
            let start: Date
            let appKey: String
            let networkKey: String
            let isProxyTransport: Bool
        }
        var values: [ExportKey: (String, TrafficTotals)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            let grouped = aggregationStart(for: timestamp, aggregation: aggregation)
            let appKey = string(statement, column: 1)
            let appName = string(statement, column: 2)
            let networkKey = string(statement, column: 3)
            let isProxyTransport = sqlite3_column_int(statement, 4) == 1
            let key = ExportKey(
                start: grouped,
                appKey: appKey,
                networkKey: networkKey,
                isProxyTransport: isProxyTransport
            )
            let current = values[key]?.1 ?? TrafficTotals()
            values[key] = (
                appName,
                TrafficTotals(
                    receivedBytes: current.receivedBytes + sqlite3_column_int64(statement, 5),
                    sentBytes: current.sentBytes + sqlite3_column_int64(statement, 6)
                )
            )
        }
        return values.map { key, value in
            TrafficExportRow(
                start: key.start,
                appKey: key.appKey,
                appName: value.0,
                networkKey: key.networkKey,
                isProxyTransport: key.isProxyTransport,
                receivedBytes: value.1.receivedBytes,
                sentBytes: value.1.sentBytes
            )
        }.sorted {
            $0.start == $1.start
                ? $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                : $0.start < $1.start
        }
    }

    public func reset() throws {
        try execute("DELETE FROM traffic_buckets")
        try execute("DELETE FROM proxy_routing_buckets")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// 记录一批代理分流的增量（按目标域名 + 是否直连），按分钟聚合写入。
    public func recordProxyRouting(_ records: [ProxyRoutingRecord], at timestamp: Date = Date()) throws {
        let active = records.filter { $0.uploadBytes > 0 || $0.downloadBytes > 0 }
        guard !active.isEmpty else { return }
        let bucketStart = Int64(timestamp.timeIntervalSince1970 / 60) * 60
        let sql =
            """
            INSERT INTO proxy_routing_buckets
                (bucket_start, target, is_direct, upload_bytes, download_bytes)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(bucket_start, target, is_direct) DO UPDATE SET
                upload_bytes = upload_bytes + excluded.upload_bytes,
                download_bytes = download_bytes + excluded.download_bytes
            """
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for record in active {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, bucketStart)
                sqlite3_bind_text(statement, 2, record.target, -1, Self.transient)
                sqlite3_bind_int(statement, 3, record.isDirect ? 1 : 0)
                sqlite3_bind_int64(statement, 4, record.uploadBytes)
                sqlite3_bind_int64(statement, 5, record.downloadBytes)
                try step(statement, sql: sql)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// 按时间范围 + 聚合粒度返回代理分流的流量曲线。
    public func proxyRoutingHistory(
        from start: Date,
        to end: Date,
        aggregation: TrafficAggregation
    ) throws -> [ProxyRoutingHistoryPoint] {
        let sql =
            """
            SELECT bucket_start, SUM(upload_bytes), SUM(download_bytes)
            FROM proxy_routing_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
            GROUP BY bucket_start
            ORDER BY bucket_start ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var totals: [Date: (up: Int64, down: Int64)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            let grouped = aggregationStart(for: timestamp, aggregation: aggregation)
            let current = totals[grouped] ?? (0, 0)
            totals[grouped] = (
                current.up + sqlite3_column_int64(statement, 1),
                current.down + sqlite3_column_int64(statement, 2)
            )
        }
        return totals.keys.sorted().map { date in
            let value = totals[date] ?? (0, 0)
            return ProxyRoutingHistoryPoint(start: date, uploadBytes: value.up, downloadBytes: value.down)
        }
    }

    /// 按目标域名汇总区间内「走代理 / 直连」的流量。
    public func proxyRoutingTargets(
        from start: Date,
        to end: Date
    ) throws -> [(target: String, isDirect: Bool, upload: Int64, download: Int64)] {
        let sql =
            """
            SELECT target, is_direct, SUM(upload_bytes), SUM(download_bytes)
            FROM proxy_routing_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
            GROUP BY target, is_direct
            ORDER BY SUM(upload_bytes + download_bytes) DESC
            LIMIT 200
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))
        var results: [(String, Bool, Int64, Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append((
                string(statement, column: 0),
                sqlite3_column_int(statement, 1) == 1,
                sqlite3_column_int64(statement, 2),
                sqlite3_column_int64(statement, 3)
            ))
        }
        return results.map { (target: $0.0, isDirect: $0.1, upload: $0.2, download: $0.3) }
    }

    public func networkKeys() throws -> [String] {
        let sql =
            """
            SELECT network_key, SUM(received_bytes + sent_bytes) AS total
            FROM traffic_buckets
            WHERE network_key <> ''
            GROUP BY network_key
            ORDER BY total DESC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(string(statement, column: 0))
        }
        return results
    }

    public func uploadAnomalies(now: Date = Date(), baselineDays: Int = 14) throws -> [UploadAnomaly] {
        let todayStart = calendar.startOfDay(for: now)
        guard let baselineStart = calendar.date(byAdding: .day, value: -max(1, baselineDays), to: todayStart)
        else { return [] }
        let sql =
            """
            SELECT app_key, MAX(app_name),
                   SUM(CASE WHEN bucket_start >= ? THEN sent_bytes ELSE 0 END),
                   SUM(CASE WHEN bucket_start < ? THEN sent_bytes ELSE 0 END)
            FROM traffic_buckets
            WHERE bucket_start >= ? AND bucket_start < ?
            GROUP BY app_key
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(todayStart.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(todayStart.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 3, Int64(baselineStart.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 4, Int64(now.timeIntervalSince1970))

        let dayCount = Int64(max(1, baselineDays))
        var results: [UploadAnomaly] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let today = sqlite3_column_int64(statement, 2)
            let average = sqlite3_column_int64(statement, 3) / dayCount
            let megabytes = Int64(1_024 * 1_024)
            // 异常判定（必须同时满足）：
            //  1) 今日上传至少 10 MB，过滤极小流量噪音；
            //  2) 若存在历史基线：今日 >= 基线日均的 3 倍；
            //     若历史无数据（average == 0）：今日需达到 100 MB 才视为异常，
            //     避免"没有基线"时把任意上传都误判为异常。
            guard today >= 10 * megabytes else { continue }
            if average > 0 {
                guard today >= average * 3 else { continue }
            } else {
                guard today >= 100 * megabytes else { continue }
            }
            results.append(
                UploadAnomaly(
                    appKey: string(statement, column: 0),
                    appName: string(statement, column: 1),
                    todaySentBytes: today,
                    baselineAverageSentBytes: average
                )
            )
        }
        return results.sorted { $0.todaySentBytes > $1.todaySentBytes }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: connection.pointer)
    }

    private static func execute(_ sql: String, on connection: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorPointer)
            throw TrafficDatabaseError.sqlite(message: message, statement: sql)
        }
    }

    private static func migrateNetworkKeyIfNeeded(on connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(traffic_buckets)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return }
        var hasNetworkKey = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1), String(cString: text) == "network_key" {
                hasNetworkKey = true
            }
        }
        sqlite3_finalize(statement)
        guard !hasNetworkKey else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: connection)
        do {
            try execute(
                """
                CREATE TABLE traffic_buckets_v2 (
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    network_key TEXT NOT NULL DEFAULT '',
                    traffic_layer INTEGER NOT NULL DEFAULT 0,
                    received_bytes INTEGER NOT NULL DEFAULT 0,
                    sent_bytes INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bucket_start, app_key, network_key, traffic_layer)
                )
                """,
                on: connection
            )
            try execute(
                """
                INSERT INTO traffic_buckets_v2
                    (bucket_start, app_key, app_name, network_key, traffic_layer, received_bytes, sent_bytes)
                SELECT bucket_start,
                    CASE WHEN app_key IN ('verge-mihomo', 'mihomo', 'clash-meta') THEN 'clash verge' ELSE app_key END,
                    CASE WHEN app_key IN ('verge-mihomo', 'mihomo', 'clash-meta') THEN 'Clash Verge' ELSE app_name END,
                    '',
                    CASE WHEN app_key IN (
                        'verge-mihomo', 'mihomo', 'clash-meta', 'clash verge',
                        'xray', 'v2ray', 'sing-box', 'openvpn', 'openvpn connect', 'wireguard-go'
                    ) THEN 1 ELSE 0 END,
                    received_bytes, sent_bytes
                FROM traffic_buckets
                """,
                on: connection
            )
            try execute("DROP TABLE traffic_buckets", on: connection)
            try execute("ALTER TABLE traffic_buckets_v2 RENAME TO traffic_buckets", on: connection)
            try execute("CREATE INDEX idx_traffic_buckets_time ON traffic_buckets(bucket_start)", on: connection)
            try execute("COMMIT", on: connection)
        } catch {
            try? execute("ROLLBACK", on: connection)
            throw error
        }
    }

    private static func migrateTrafficLayerIfNeeded(on connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(traffic_buckets)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return }
        var hasLayer = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1), String(cString: text) == "traffic_layer" {
                hasLayer = true
            }
        }
        sqlite3_finalize(statement)
        guard !hasLayer else { return }

        try execute("BEGIN IMMEDIATE TRANSACTION", on: connection)
        do {
            try execute(
                """
                CREATE TABLE traffic_buckets_v3 (
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    network_key TEXT NOT NULL DEFAULT '',
                    traffic_layer INTEGER NOT NULL DEFAULT 0,
                    received_bytes INTEGER NOT NULL DEFAULT 0,
                    sent_bytes INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bucket_start, app_key, network_key, traffic_layer)
                )
                """,
                on: connection
            )
            try execute(
                """
                INSERT INTO traffic_buckets_v3
                    (bucket_start, app_key, app_name, network_key, traffic_layer, received_bytes, sent_bytes)
                SELECT bucket_start,
                    CASE WHEN app_key IN ('verge-mihomo', 'mihomo', 'clash-meta') THEN 'clash verge' ELSE app_key END,
                    CASE WHEN app_key IN ('verge-mihomo', 'mihomo', 'clash-meta') THEN 'Clash Verge' ELSE app_name END,
                    network_key,
                    CASE WHEN app_key IN (
                        'verge-mihomo', 'mihomo', 'clash-meta', 'clash verge',
                        'xray', 'v2ray', 'sing-box', 'openvpn', 'openvpn connect', 'wireguard-go'
                    ) THEN 1 ELSE 0 END,
                    received_bytes, sent_bytes
                FROM traffic_buckets
                """,
                on: connection
            )
            try execute("DROP TABLE traffic_buckets", on: connection)
            try execute("ALTER TABLE traffic_buckets_v3 RENAME TO traffic_buckets", on: connection)
            try execute("CREATE INDEX idx_traffic_buckets_time ON traffic_buckets(bucket_start)", on: connection)
            try execute("COMMIT", on: connection)
        } catch {
            try? execute("ROLLBACK", on: connection)
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw sqliteError(statement: sql)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer, sql: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(statement: sql)
        }
    }

    private func sqliteError(statement: String) -> TrafficDatabaseError {
        let message = String(cString: sqlite3_errmsg(connection.pointer))
        return .sqlite(message: message, statement: statement)
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    private func bindOptionalText(_ value: String?, statement: OpaquePointer, index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func aggregationStart(for date: Date, aggregation: TrafficAggregation) -> Date {
        switch aggregation {
        case .minute:
            return calendar.dateInterval(of: .minute, for: date)?.start ?? date
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    private func accountingClause(_ mode: TrafficAccountingMode) -> String {
        let proxies =
            "'verge-mihomo','mihomo','clash-meta','clash verge','xray','v2ray'," +
            "'sing-box','openvpn','openvpn connect','wireguard-go'"
        switch mode {
        case .application:
            return "AND traffic_layer = 0 AND app_key NOT IN (\(proxies))"
        case .gateway:
            return "AND (traffic_layer = 1 OR app_key IN (\(proxies)))"
        case .diagnostic:
            return ""
        }
    }
}
