import Charts
import SwiftUI
import TrafficCore

/// 代理分流：通过 Clash/mihomo 的 /connections 接口，按「目标域名」展示
/// 哪些流量走代理节点、哪些走直连（DIRECT）。
struct ProxyRoutingDashboard: View {
    @ObservedObject var store: TrafficMonitorStore
    @State private var filter: RoutingFilter = .all
    @State private var searchText = ""
    @State private var preset: RoutingPreset = .today
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var aggregation: TrafficAggregation = .hour
    @State private var groupByService = true

    enum RoutingPreset: String, CaseIterable, Identifiable {
        case today = "今天"
        case sevenDays = "7 天"
        case thirtyDays = "30 天"
        case thisMonth = "本月"
        case lastMonth = "上月"
        case custom = "自定义"
        var id: String { rawValue }
    }

    private var range: DateInterval {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch preset {
        case .today:
            return DateInterval(start: today, end: now)
        case .sevenDays:
            return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: today) ?? today, end: now)
        case .thirtyDays:
            return DateInterval(start: calendar.date(byAdding: .day, value: -29, to: today) ?? today, end: now)
        case .thisMonth:
            return DateInterval(start: calendar.dateInterval(of: .month, for: now)?.start ?? today, end: now)
        case .lastMonth:
            let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
            let start = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
            return DateInterval(start: start, end: thisMonth)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: endDay) ?? now
            return DateInterval(start: start, end: min(exclusiveEnd, now))
        }
    }

    enum RoutingFilter: String, CaseIterable, Identifiable {
        case all, proxied, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .proxied: "走代理"
            case .direct: "直连"
            }
        }
    }

    private var snapshot: ProxyRoutingSnapshot { store.proxyRouting }

    private var filteredEntries: [ProxyRoutingEntry] {
        snapshot.entries.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .proxied: matchesFilter = !entry.isDirect
            case .direct: matchesFilter = entry.isDirect
            }
            let matchesSearch = searchText.isEmpty
                || entry.target.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !snapshot.isAvailable {
                    unavailableCard
                } else {
                    rangeControls
                    summaryCards
                    accountingNote
                    historyChart
                    historyTargetsTable
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DashboardBackground())
        .navigationTitle("代理")
        .task { await reloadHistory() }
        .onChange(of: preset) { _, _ in Task { await reloadHistory() } }
        .onChange(of: aggregation) { _, _ in Task { await reloadHistory() } }
        .onChange(of: customStart) { _, _ in if preset == .custom { Task { await reloadHistory() } } }
        .onChange(of: customEnd) { _, _ in if preset == .custom { Task { await reloadHistory() } } }
    }

    private func reloadHistory() async {
        await store.loadProxyHistory(from: range.start, to: range.end, aggregation: aggregation)
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return "\(f.string(from: range.start)) – \(f.string(from: range.end))"
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("代理")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("基于 Clash 连接的真实出站走向：哪些目标走代理、哪些直连")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refreshProxyRouting() }
            } label: {
                if store.isRefreshingProxyRouting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshingProxyRouting)
        }
    }

    private var unavailableCard: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("无法读取 Clash 分流数据", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(snapshot.errorMessage ?? "未知错误")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("需要 Clash Verge / mihomo 正在运行，且开启了外部控制（外部控制器 socket）。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !snapshot.socketPath.isEmpty {
                    Text("探测路径：\(snapshot.socketPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            ProxyMetric(
                title: "区间总流量",
                value: TrafficByteFormatter.string(fromByteCount: rangeTotal),
                tint: .blue,
                subtitle: rangeLabelShort
            )
            ProxyMetric(
                title: "区间·走代理",
                value: TrafficByteFormatter.string(fromByteCount: rangeProxiedBytes),
                tint: .purple,
                subtitle: rangePercent(rangeProxiedBytes)
            )
            ProxyMetric(
                title: "区间·直连",
                value: TrafficByteFormatter.string(fromByteCount: rangeDirectBytes),
                tint: .green,
                subtitle: rangePercent(rangeDirectBytes)
            )
            ProxyMetric(
                title: "区间目标数",
                value: "\(store.proxyHistoryTargets.count)",
                tint: .orange,
                subtitle: "去重后的目标"
            )
        }
    }

    private var rangeLabelShort: String {
        switch preset {
        case .today: "今天"
        case .sevenDays: "近 7 天"
        case .thirtyDays: "近 30 天"
        case .thisMonth: "本月"
        case .lastMonth: "上月"
        case .custom: "自定义区间"
        }
    }

    private var rangeProxiedBytes: Int64 {
        store.proxyHistoryTargets.filter { !$0.isDirect }.reduce(0) { $0 + $1.upload + $1.download }
    }
    private var rangeDirectBytes: Int64 {
        store.proxyHistoryTargets.filter { $0.isDirect }.reduce(0) { $0 + $1.upload + $1.download }
    }
    private func rangePercent(_ bytes: Int64) -> String {
        guard rangeTotal > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(bytes) / Double(rangeTotal) * 100)
    }

    private var accountingNote: some View {
        Text("说明：上方所有统计均按当前选中的时间范围（今天 / 7 天 / 30 天 / 本月 / 上月 / 自定义）聚合展示。数据来自本机按时间采样的代理流量记录，仅统计本版本运行期间的数据。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 范围统计（按时间段 + 聚合）

    private var rangeControls: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("范围", selection: $preset) {
                    ForEach(RoutingPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    if preset == .custom {
                        DatePicker("开始", selection: $customStart, displayedComponents: .date)
                        DatePicker("结束", selection: $customEnd, displayedComponents: .date)
                    } else {
                        Text(rangeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("聚合", selection: $aggregation) {
                        Text("分钟").tag(TrafficAggregation.minute)
                        Text("小时").tag(TrafficAggregation.hour)
                        Text("每天").tag(TrafficAggregation.day)
                        Text("每月").tag(TrafficAggregation.month)
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 120)
                }
            }
        }
    }

    private var rangeTotal: Int64 {
        store.proxyHistoryPoints.reduce(0) { $0 + $1.totalBytes }
    }

    private var historyChart: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("区间流量").font(.headline)
                    Spacer()
                    Text("合计 \(TrafficByteFormatter.string(fromByteCount: rangeTotal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.proxyHistoryPoints.isEmpty {
                    ContentUnavailableView(
                        "该区间暂无数据",
                        systemImage: "chart.xyaxis.line",
                        description: Text("代理分流数据从本版本开始按分钟采样记录，稍后即有数据。")
                    )
                    .frame(height: 160)
                } else {
                    Chart(store.proxyHistoryPoints) { point in
                        AreaMark(
                            x: .value("时间", point.start),
                            y: .value("总流量", point.totalBytes)
                        )
                        .foregroundStyle(.purple.opacity(0.12))
                        .interpolationMethod(.monotone)
                        LineMark(
                            x: .value("时间", point.start),
                            y: .value("上传", point.uploadBytes)
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                        LineMark(
                            x: .value("时间", point.start),
                            y: .value("下载", point.downloadBytes)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) {
                                    Text(TrafficByteFormatter.string(fromByteCount: bytes))
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
    }

    private struct DisplayRow: Identifiable {
        let id: String
        let label: String
        let isDirect: Bool
        let upload: Int64
        let download: Int64
        var total: Int64 { upload + download }
    }

    private var displayRows: [DisplayRow] {
        let raw = store.proxyHistoryTargets
        guard groupByService else {
            return raw.prefix(30).map {
                DisplayRow(id: "\($0.target)|\($0.isDirect)", label: $0.target,
                           isDirect: $0.isDirect, upload: $0.upload, download: $0.download)
            }
        }
        var buckets: [String: (up: Int64, down: Int64, direct: Bool)] = [:]
        for item in raw {
            let service = Self.serviceName(for: item.target)
            let key = "\(service)|\(item.isDirect)"
            let cur = buckets[key] ?? (0, 0, item.isDirect)
            buckets[key] = (cur.up + item.upload, cur.down + item.download, item.isDirect)
        }
        return buckets.map { key, v in
            DisplayRow(id: key, label: String(key.split(separator: "|").first ?? ""),
                       isDirect: v.direct, upload: v.up, download: v.down)
        }
        .sorted { $0.total > $1.total }
        .prefix(30)
        .map { $0 }
    }

    private static func serviceName(for target: String) -> String {
        let lower = target.lowercased()
        if lower.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return target
        }
        let knownTwoPartSuffixes = ["com.cn", "co.uk", "com.hk", "net.cn", "org.cn", "co.jp"]
        let parts = lower.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return lower }
        if parts.count >= 3 {
            let last2 = parts.suffix(2).joined(separator: ".")
            if knownTwoPartSuffixes.contains(last2) {
                return parts.suffix(3).joined(separator: ".")
            }
        }
        return parts.suffix(2).joined(separator: ".")
    }

    private var historyTargetsTable: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("区间内流量去向").font(.headline).fixedSize()
                    Spacer(minLength: 8)
                    Picker("分组", selection: $groupByService) {
                        Text("按服务").tag(true)
                        Text("按域名").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .fixedSize()
                }

                if displayRows.isEmpty {
                    Text("该区间暂无数据").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    HStack {
                        Text(groupByService ? "服务" : "目标").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("走向").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text("上传").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Text("下载").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Text("合计").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }
                    Divider()
                    ForEach(displayRows) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirect ? "arrow.right.circle.fill" : "shield.lefthalf.filled")
                                .foregroundStyle(item.isDirect ? .green : .purple)
                            Text(item.label).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.isDirect ? "直连" : "代理")
                                .font(.caption)
                                .foregroundStyle(item.isDirect ? .green : .secondary)
                                .frame(width: 60, alignment: .leading)
                            Text(TrafficByteFormatter.string(fromByteCount: item.upload))
                                .font(.caption.monospacedDigit()).frame(width: 90, alignment: .trailing)
                            Text(TrafficByteFormatter.string(fromByteCount: item.download))
                                .font(.caption.monospacedDigit()).frame(width: 90, alignment: .trailing)
                            Text(TrafficByteFormatter.string(fromByteCount: item.total))
                                .font(.caption.monospacedDigit()).frame(width: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider().opacity(0.4)
                    }
                }

                Text(groupByService
                     ? "按服务为近似归并（同域名子主机合并，如 ab.chatgpt.com → chatgpt.com）。Clash 服务模式不提供发起进程，故无法按 App 进程精确归属。"
                     : "按完整目标域名展示。Clash 服务模式不提供发起进程，故无法按 App 进程精确归属。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func percentText(_ bytes: Int64) -> String {
        guard snapshot.totalBytes > 0 else { return "0%" }
        let p = Double(bytes) / Double(snapshot.totalBytes) * 100
        return String(format: "%.0f%%", p)
    }

    private var splitChart: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("代理 / 直连占比").font(.headline)
                Chart {
                    BarMark(
                        x: .value("类型", "直连"),
                        y: .value("流量", snapshot.directBytes)
                    )
                    .foregroundStyle(.green)
                    BarMark(
                        x: .value("类型", "走代理"),
                        y: .value("流量", snapshot.proxiedBytes)
                    )
                    .foregroundStyle(.purple)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(TrafficByteFormatter.string(fromByteCount: bytes))
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var routingTable: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("按目标域名").font(.headline).fixedSize()
                    Spacer(minLength: 8)
                    Picker("筛选", selection: $filter) {
                        ForEach(RoutingFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    .fixedSize()
                    TextField("搜索域名", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .fixedSize()
                }

                HStack {
                    Text("目标").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("走向").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text("上传").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Text("下载").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Text("合计").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                }
                .padding(.top, 4)

                Divider()

                ForEach(filteredEntries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirect ? "arrow.right.circle.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(entry.isDirect ? .green : .purple)
                        Text(entry.target)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(entry.isDirect ? "直连" : entry.chain)
                            .font(.caption)
                            .foregroundStyle(entry.isDirect ? .green : .secondary)
                            .lineLimit(1)
                            .frame(width: 90, alignment: .leading)
                        Text(TrafficByteFormatter.string(fromByteCount: entry.uploadBytes))
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                        Text(TrafficByteFormatter.string(fromByteCount: entry.downloadBytes))
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                        Text(TrafficByteFormatter.string(fromByteCount: entry.totalBytes))
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }

                if filteredEntries.isEmpty {
                    Text("没有匹配的目标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}

private struct ProxyMetric: View {
    let title: String
    let value: String
    let tint: Color
    var subtitle: String? = nil

    var body: some View {
        ProxyCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProxyCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.045), radius: 10, y: 3)
    }
}
