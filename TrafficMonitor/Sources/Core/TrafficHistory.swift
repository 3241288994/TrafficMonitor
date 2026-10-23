import Foundation

public struct TrafficTotals: Equatable, Sendable {
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(receivedBytes: Int64 = 0, sentBytes: Int64 = 0) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct AppTrafficSummary: Identifiable, Equatable, Sendable {
    public let appKey: String
    public let appName: String
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var id: String { appKey }
    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(
        appKey: String,
        appName: String,
        receivedBytes: Int64,
        sentBytes: Int64
    ) {
        self.appKey = appKey
        self.appName = appName
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct DailyTrafficTotal: Identifiable, Equatable, Sendable {
    public let day: Date
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var id: Date { day }
    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(day: Date, receivedBytes: Int64, sentBytes: Int64) {
        self.day = day
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public enum TrafficAggregation: String, CaseIterable, Codable, Sendable {
    case minute
    case hour
    case day
    case month
}

public struct TrafficHistoryPoint: Identifiable, Equatable, Sendable {
    public let start: Date
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var id: Date { start }
    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(start: Date, receivedBytes: Int64, sentBytes: Int64) {
        self.start = start
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct HourlyHeatmapCell: Identifiable, Equatable, Sendable {
    public let weekday: Int
    public let hour: Int
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var id: String { "\(weekday)-\(hour)" }
    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(weekday: Int, hour: Int, receivedBytes: Int64, sentBytes: Int64) {
        self.weekday = weekday
        self.hour = hour
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct UploadAnomaly: Identifiable, Equatable, Sendable {
    public let appKey: String
    public let appName: String
    public let todaySentBytes: Int64
    public let baselineAverageSentBytes: Int64

    public var id: String { appKey }
    public var multiple: Double {
        baselineAverageSentBytes > 0
            ? Double(todaySentBytes) / Double(baselineAverageSentBytes)
            : 0
    }

    public init(appKey: String, appName: String, todaySentBytes: Int64, baselineAverageSentBytes: Int64) {
        self.appKey = appKey
        self.appName = appName
        self.todaySentBytes = todaySentBytes
        self.baselineAverageSentBytes = baselineAverageSentBytes
    }
}

public struct TrafficExportRow: Equatable, Sendable {
    public let start: Date
    public let appKey: String
    public let appName: String
    public let networkKey: String
    public let isProxyTransport: Bool
    public let receivedBytes: Int64
    public let sentBytes: Int64

    public var totalBytes: Int64 { receivedBytes + sentBytes }

    public init(
        start: Date,
        appKey: String,
        appName: String,
        networkKey: String = "",
        isProxyTransport: Bool = false,
        receivedBytes: Int64,
        sentBytes: Int64
    ) {
        self.start = start
        self.appKey = appKey
        self.appName = appName
        self.networkKey = networkKey
        self.isProxyTransport = isProxyTransport
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public enum TrafficByteFormatter {
    public static func string(fromByteCount bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// 代理分流按时间的聚合点（供「代理」页的范围统计使用）。
public struct ProxyRoutingHistoryPoint: Identifiable, Equatable, Sendable {
    public let start: Date
    public let uploadBytes: Int64
    public let downloadBytes: Int64

    public var id: Date { start }
    public var totalBytes: Int64 { uploadBytes + downloadBytes }

    public init(start: Date, uploadBytes: Int64, downloadBytes: Int64) {
        self.start = start
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }
}

/// 代理分流的历史记录条目（写入用）。
public struct ProxyRoutingRecord: Sendable, Equatable {
    public let target: String
    public let isDirect: Bool
    public let uploadBytes: Int64
    public let downloadBytes: Int64

    public init(target: String, isDirect: Bool, uploadBytes: Int64, downloadBytes: Int64) {
        self.target = target
        self.isDirect = isDirect
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }
}
