import Foundation
import Testing
@testable import TrafficCore

struct TrafficDatabaseTests {
    @Test func recordsAndAggregatesTraffic() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try DatabaseFixture(calendar: calendar)
        defer { fixture.remove() }

        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.database.record(
            TrafficSnapshot(
                timestamp: firstDate,
                processes: [
                    ProcessTraffic(
                        pid: 1,
                        processName: "Browser",
                        receivedBytes: 1_000,
                        sentBytes: 500,
                        sampleDuration: 2
                    ),
                    ProcessTraffic(
                        pid: 2,
                        processName: "Sync",
                        receivedBytes: 200,
                        sentBytes: 800,
                        sampleDuration: 2
                    ),
                    ProcessTraffic(
                        pid: 4,
                        processName: "verge-mihomo",
                        receivedBytes: 9_000,
                        sentBytes: 9_000,
                        sampleDuration: 2
                    )
                ]
            )
        )
        try await fixture.database.record(
            TrafficSnapshot(
                timestamp: firstDate.addingTimeInterval(20),
                processes: [
                    ProcessTraffic(
                        pid: 3,
                        processName: "Browser",
                        receivedBytes: 500,
                        sentBytes: 100,
                        sampleDuration: 2
                    )
                ]
            )
        )

        let totals = try await fixture.database.totals(
            from: firstDate.addingTimeInterval(-60),
            to: firstDate.addingTimeInterval(120)
        )
        #expect(totals.receivedBytes == 1_700)
        #expect(totals.sentBytes == 1_400)

        let apps = try await fixture.database.topApps(
            from: firstDate.addingTimeInterval(-60),
            to: firstDate.addingTimeInterval(120)
        )
        #expect(apps.map(\.appName) == ["Browser", "Sync"])
        #expect(apps[0].totalBytes == 2_100)
    }

    @Test func returnsZeroFilledDailySeriesAndCanReset() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try DatabaseFixture(calendar: calendar)
        defer { fixture.remove() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.database.record(
            TrafficSnapshot(
                timestamp: now,
                processes: [
                    ProcessTraffic(
                        pid: 9,
                        processName: "Downloader",
                        receivedBytes: 4_096,
                        sentBytes: 256,
                        sampleDuration: 2
                    )
                ]
            )
        )

        let days = try await fixture.database.dailyTotals(days: 7, endingAt: now)
        #expect(days.count == 7)
        #expect(days.last?.totalBytes == 4_352)
        #expect(days.dropLast().allSatisfy { $0.totalBytes == 0 })

        try await fixture.database.reset()
        let totals = try await fixture.database.totals(
            from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(3_600)
        )
        #expect(totals.totalBytes == 0)
    }

    @Test func groupsHistoryAndSeparatesNetworks() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try DatabaseFixture(calendar: calendar)
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await fixture.database.record(
            TrafficSnapshot(timestamp: start, processes: [
                ProcessTraffic(pid: 1, processName: "Browser", receivedBytes: 1_000, sentBytes: 100, sampleDuration: 2)
            ]),
            networkKey: "Home Wi-Fi"
        )
        try await fixture.database.record(
            TrafficSnapshot(timestamp: start.addingTimeInterval(3_700), processes: [
                ProcessTraffic(pid: 1, processName: "Browser", receivedBytes: 2_000, sentBytes: 200, sampleDuration: 2)
            ]),
            networkKey: "Hotspot"
        )

        let home = try await fixture.database.totals(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(7_200),
            networkKey: "Home Wi-Fi"
        )
        #expect(home.totalBytes == 1_100)
        let networks = try await fixture.database.networkKeys()
        #expect(Set(networks) == Set(["Home Wi-Fi", "Hotspot"]))
        let hourly = try await fixture.database.history(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(7_200),
            aggregation: .hour
        )
        #expect(hourly.count == 2)
        #expect(hourly.reduce(0) { $0 + $1.totalBytes } == 3_300)
        let exported = try await fixture.database.exportRows(
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(7_200),
            aggregation: .hour
        )
        #expect(Set(exported.map(\.networkKey)) == Set(["Home Wi-Fi", "Hotspot"]))
    }

    @Test func appliesApplicationGatewayAndDiagnosticAccounting() async throws {
        let fixture = try DatabaseFixture(calendar: Calendar(identifier: .gregorian))
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.database.record(
            TrafficSnapshot(timestamp: now, processes: [
                ProcessTraffic(pid: 1, processName: "SSH", receivedBytes: 100, sentBytes: 20, sampleDuration: 2),
                ProcessTraffic(pid: 2, processName: "Clash Verge", receivedBytes: 1_000, sentBytes: 200, sampleDuration: 2, isProxyTransport: true)
            ])
        )
        let start = now.addingTimeInterval(-60)
        let end = now.addingTimeInterval(60)
        let application = try await fixture.database.totals(from: start, to: end, accountingMode: .application)
        let gateway = try await fixture.database.totals(from: start, to: end, accountingMode: .gateway)
        let diagnostic = try await fixture.database.totals(from: start, to: end, accountingMode: .diagnostic)
        #expect(application.totalBytes == 120)
        #expect(gateway.totalBytes == 1_200)
        #expect(diagnostic.totalBytes == 1_320)
        let gatewayApps = try await fixture.database.topApps(from: start, to: end, accountingMode: .gateway)
        #expect(gatewayApps.map(\.appName) == ["Clash Verge"])
    }

    @Test func uploadAnomaliesRequireBaselineOrLargeSpike() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try DatabaseFixture(calendar: calendar)
        defer { fixture.remove() }

        let mb = Int64(1_024 * 1_024)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let todayStart = calendar.startOfDay(for: now)

        // 今日"微小"上传：仅 20 MB，且历史无基线 —— 不应被判为异常。
        try await fixture.database.record(
            TrafficSnapshot(timestamp: todayStart.addingTimeInterval(3600), processes: [
                ProcessTraffic(pid: 10, processName: "TinySync", receivedBytes: 0, sentBytes: 20 * mb, sampleDuration: 2)
            ])
        )

        // 有历史基线的应用：过去几天日均约 10 MB，今日上传 100 MB（10 倍）—— 应判为异常。
        for dayOffset in 1...3 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: todayStart)!
            try await fixture.database.record(
                TrafficSnapshot(timestamp: day.addingTimeInterval(3600), processes: [
                    ProcessTraffic(pid: 11, processName: "Backup", receivedBytes: 0, sentBytes: 10 * mb, sampleDuration: 2)
                ])
            )
        }
        try await fixture.database.record(
            TrafficSnapshot(timestamp: todayStart.addingTimeInterval(7200), processes: [
                ProcessTraffic(pid: 11, processName: "Backup", receivedBytes: 0, sentBytes: 100 * mb, sampleDuration: 2)
            ])
        )

        let anomalies = try await fixture.database.uploadAnomalies(now: todayStart.addingTimeInterval(8000))
        let names = Set(anomalies.map(\.appName))
        #expect(names.contains("Backup"))
        #expect(!names.contains("TinySync"))
    }
}

private final class DatabaseFixture: @unchecked Sendable {
    let directory: URL
    private var databaseStorage: TrafficDatabase?

    var database: TrafficDatabase {
        guard let databaseStorage else {
            preconditionFailure("测试数据库已关闭")
        }
        return databaseStorage
    }

    init(calendar: Calendar) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrafficMonitorTests-\(UUID().uuidString)", isDirectory: true)
        databaseStorage = try TrafficDatabase(
            url: directory.appendingPathComponent("traffic.sqlite"),
            calendar: calendar
        )
    }

    func remove() {
        databaseStorage = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
