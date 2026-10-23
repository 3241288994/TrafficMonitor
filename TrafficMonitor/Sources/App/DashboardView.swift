import Charts
import SwiftUI
import TrafficCore

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case history
    case apps
    case routing
    case network
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .history: "历史"
        case .apps: "应用"
        case .routing: "代理"
        case .network: "网络"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .history: "calendar"
        case .apps: "square.grid.2x2"
        case .routing: "arrow.triangle.branch"
        case .network: "network"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: TrafficMonitorStore
    var statusBarController: MenuBarStatusController?
    @State private var selection: DashboardSection? = .overview

    /// 未检测到本机 Clash/mihomo 时隐藏「代理分流」入口。
    private var visibleSections: [DashboardSection] {
        DashboardSection.allCases.filter { section in
            section != .routing || store.isClashAvailable
        }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSections, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.icon)
                        .imageScale(.medium)
                }
                .labelStyle(.titleAndIcon)
                .frame(maxHeight: .infinity, alignment: .center)
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("流量监控")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    OverviewDashboard(store: store)
                case .history:
                    HistoryDashboard(store: store)
                case .network:
                    NetworkQualityDashboard(monitor: store.qualityMonitor)
                case .apps:
                    AppsDashboard(store: store)
                case .routing:
                    ProxyRoutingDashboard(store: store)
                case .settings:
                    SettingsDashboard(store: store, menuBarController: statusBarController)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Picker(
                            "统计口径",
                            selection: Binding(
                                get: { store.accountingMode },
                                set: { store.setAccountingMode($0) }
                            )
                        ) {
                            ForEach(TrafficAccountingMode.allCases, id: \.rawValue) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(minWidth: 120)
                        .help("统计口径")

                        HStack(spacing: 6) {
                            Circle()
                                .fill(store.errorMessage == nil ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(store.errorMessage == nil ? "正在监控" : "采集异常")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }

                        Button {
                            Task { await store.refreshHistory() }
                        } label: {
                            if store.isRefreshingHistory {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .help("刷新历史统计")
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.isClashAvailable) { _, available in
            if !available, selection == .routing {
                selection = .overview
            }
        }
    }
}

private struct OverviewDashboard: View {
    @ObservedObject var store: TrafficMonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                HistoryErrorBanner(message: store.historyErrorMessage)
                summaryCards
                if !store.uploadAnomalies.isEmpty {
                    CompactAnomalyCard(anomalies: store.uploadAnomalies)
                }
                LiveChartCard(points: store.livePoints)
                SevenDayChartCard(days: store.dailyTotals)
                TopAppsCard(store: store)
            }
            .padding(24)
        }
        .background(DashboardBackground())
        .navigationTitle("概览")
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("网络用量概览")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("所有数据仅保存在这台 Mac 上")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(store.accountingMode.title, systemImage: store.accountingMode == .diagnostic ? "exclamationmark.triangle" : "point.3.connected.trianglepath.dotted")
                .font(.caption)
                .foregroundStyle(store.accountingMode == .diagnostic ? .orange : .secondary)
        }
    }

    private var summaryCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            spacing: 12
        ) {
            MetricCard(
                title: "今天",
                value: TrafficByteFormatter.string(fromByteCount: store.todayTotals.totalBytes),
                subtitle: directionSummary(store.todayTotals),
                icon: "sun.max.fill",
                tint: .orange
            )
            MetricCard(
                title: "本周",
                value: TrafficByteFormatter.string(fromByteCount: store.weekTotals.totalBytes),
                subtitle: directionSummary(store.weekTotals),
                icon: "calendar",
                tint: .indigo
            )
            MetricCard(
                title: "本月",
                value: TrafficByteFormatter.string(fromByteCount: store.monthTotals.totalBytes),
                subtitle: "共 \(store.topApps.count) 个活跃应用",
                icon: "chart.bar.fill",
                tint: .blue
            )
            MetricCard(
                title: "当前速率",
                value: ByteRateFormatter.string(
                    from: store.snapshot.totalReceivedBytesPerSecond
                        + store.snapshot.totalSentBytesPerSecond
                ),
                subtitle: "↑ \(ByteRateFormatter.compactString(from: store.snapshot.totalSentBytesPerSecond))  ↓ \(ByteRateFormatter.compactString(from: store.snapshot.totalReceivedBytesPerSecond))",
                icon: "bolt.horizontal.fill",
                tint: .green
            )
        }
    }

    private func directionSummary(_ totals: TrafficTotals) -> String {
        "↑ \(TrafficByteFormatter.string(fromByteCount: totals.sentBytes))  ↓ \(TrafficByteFormatter.string(fromByteCount: totals.receivedBytes))"
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        DashboardCard {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct SevenDayChartCard: View {
    let days: [DailyTrafficTotal]
    @State private var hoveredDay: DailyTrafficTotal?

    private var sevenDayTotal: Int64 {
        days.reduce(0) { $0 + $1.totalBytes }
    }

    private var yMaximum: Double {
        max(Double(days.map(\.totalBytes).max() ?? 0) * 1.15, 1_024)
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近 7 天")
                            .font(.headline)
                        Text("总计 \(TrafficByteFormatter.string(fromByteCount: sevenDayTotal))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("每日总用量", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Chart(days) { item in
                    AreaMark(
                        x: .value("日期", item.day, unit: .day),
                        y: .value("流量", item.totalBytes)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.32), .blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("日期", item.day, unit: .day),
                        y: .value("流量", item.totalBytes)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("日期", item.day, unit: .day),
                        y: .value("流量", item.totalBytes)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(22)

                    if hoveredDay?.id == item.id {
                        RuleMark(x: .value("选中日期", item.day, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, spacing: 8) {
                                TrafficChartTooltip(
                                    title: item.day.formatted(.dateTime.month().day().weekday(.wide)),
                                    received: item.receivedBytes,
                                    sent: item.sentBytes
                                )
                            }
                    }
                }
                .chartYScale(domain: 0...yMaximum)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(
                                    TrafficByteFormatter.string(
                                        fromByteCount: Int64(number)
                                    )
                                )
                            }
                        }
                    }
                }
                .frame(height: 220)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = location.x - frame.minX
                                    guard x >= 0, x <= frame.width,
                                          let date: Date = proxy.value(atX: x)
                                    else { hoveredDay = nil; return }
                                    hoveredDay = days.min {
                                        abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
                                    }
                                case .ended:
                                    hoveredDay = nil
                                }
                            }
                    }
                }
            }
        }
    }
}

private struct TopAppsCard: View {
    @ObservedObject var store: TrafficMonitorStore

    private let columns = [
        GridItem(.adaptive(minimum: 230), spacing: 10)
    ]

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本月流量最多的应用")
                        .font(.headline)
                    Text("按上传和下载总量排序")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.topApps.isEmpty {
                    ContentUnavailableView(
                        "暂无历史数据",
                        systemImage: "chart.bar.xaxis",
                        description: Text("保持应用运行，统计会自动出现在这里。")
                    )
                    .frame(height: 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.topApps.prefix(9)) { app in
                            TopAppTile(
                                app: app,
                                totalMonthBytes: store.monthTotals.totalBytes,
                                pid: livePID(for: app.appName)
                            )
                        }
                    }
                }
            }
        }
    }

    private func livePID(for name: String) -> Int32? {
        store.snapshot.processes.first { $0.processName == name }?.pid
    }
}

private struct TopAppTile: View {
    let app: AppTrafficSummary
    let totalMonthBytes: Int64
    let pid: Int32?

    private var percentage: Double {
        guard totalMonthBytes > 0 else { return 0 }
        return Double(app.totalBytes) / Double(totalMonthBytes) * 100
    }

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(name: app.appName, pid: pid, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(
                    "\(TrafficByteFormatter.string(fromByteCount: app.totalBytes)) · \(percentage, format: .number.precision(.fractionLength(0...1)))%"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LiveDashboard: View {
    @ObservedObject var store: TrafficMonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时流量")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("最近 4 分钟 · 每 2 秒采样")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    LiveRateCard(
                        title: "下载",
                        value: store.snapshot.totalReceivedBytesPerSecond,
                        icon: "arrow.down",
                        tint: .blue
                    )
                    LiveRateCard(
                        title: "上传",
                        value: store.snapshot.totalSentBytesPerSecond,
                        icon: "arrow.up",
                        tint: .orange
                    )
                }

                LiveChartCard(points: store.livePoints)
                ActiveProcessesCard(store: store)
            }
            .padding(24)
        }
        .background(DashboardBackground())
        .navigationTitle("实时")
    }
}

private struct LiveRateCard: View {
    let title: String
    let value: Double
    let icon: String
    let tint: Color

    var body: some View {
        DashboardCard {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ByteRateFormatter.string(from: value))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveChartCard: View {
    let points: [LiveTrafficPoint]
    @State private var hoveredPoint: LiveTrafficPoint?

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("实时速率曲线")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 12) {
                        LegendDot(color: .blue, title: "下载")
                        LegendDot(color: .orange, title: "上传")
                    }
                }

                if points.isEmpty {
                    ContentUnavailableView(
                        "等待采样",
                        systemImage: "waveform.path.ecg",
                        description: Text("网络活动出现后会绘制实时曲线。")
                    )
                    .frame(height: 230)
                } else {
                    Chart(points) { point in
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("下载", point.receivedBytesPerSecond)
                        )
                        .foregroundStyle(by: .value("方向", "下载"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)

                        if hoveredPoint?.id == point.id {
                            RuleMark(x: .value("选中时间", point.timestamp))
                                .foregroundStyle(.secondary.opacity(0.4))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 8) {
                                    TrafficChartTooltip(
                                        title: point.timestamp.formatted(date: .omitted, time: .standard),
                                        received: Int64(point.receivedBytesPerSecond),
                                        sent: Int64(point.sentBytesPerSecond),
                                        showsRate: true
                                    )
                                }
                        }

                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("上传", point.sentBytesPerSecond)
                        )
                        .foregroundStyle(by: .value("方向", "上传"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale([
                        "下载": Color.blue,
                        "上传": Color.orange
                    ])
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(ByteRateFormatter.compactString(from: number))
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let frame = geometry[plotFrame]
                                        let x = location.x - frame.minX
                                        guard x >= 0, x <= frame.width,
                                              let date: Date = proxy.value(atX: x)
                                        else { hoveredPoint = nil; return }
                                        hoveredPoint = points.min {
                                            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
                                        }
                                    case .ended:
                                        hoveredPoint = nil
                                    }
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActiveProcessesCard: View {
    @ObservedObject var store: TrafficMonitorStore

    private var processes: [ProcessTraffic] {
        store.snapshot.processes
            .filter { $0.totalBytesPerSecond > 0 }
            .sorted { $0.totalBytesPerSecond > $1.totalBytesPerSecond }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("当前活跃进程")
                    .font(.headline)

                if processes.isEmpty {
                    Text("当前没有检测到网络活动。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                } else {
                    ForEach(processes.prefix(12)) { process in
                        HStack(spacing: 10) {
                            AppIconView(name: process.processName, pid: process.pid, size: 28)
                            Text(process.processName)
                                .lineLimit(1)
                            Spacer()
                            Text("↑ \(ByteRateFormatter.compactString(from: process.sentBytesPerSecond))")
                                .foregroundStyle(.orange)
                            Text("↓ \(ByteRateFormatter.compactString(from: process.receivedBytesPerSecond))")
                                .foregroundStyle(.blue)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

private struct AppsDashboard: View {
    @ObservedObject var store: TrafficMonitorStore
    @State private var searchText = ""
    @State private var sortMode: AppSortMode = .total
    @State private var minimumMB = 0.0

    private var filteredApps: [AppTrafficSummary] {
        store.appPeriodApps
            .filter {
                (searchText.isEmpty || $0.appName.localizedCaseInsensitiveContains(searchText))
                    && Double($0.totalBytes) >= minimumMB * 1_048_576
            }
            .sorted {
                switch sortMode {
                case .total: $0.totalBytes > $1.totalBytes
                case .download: $0.receivedBytes > $1.receivedBytes
                case .upload: $0.sentBytes > $1.sentBytes
                case .name: $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("应用流量")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(store.appUsagePeriod.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker(
                        "时间范围",
                        selection: Binding(
                            get: { store.appUsagePeriod },
                            set: { period in
                                Task { await store.setAppUsagePeriod(period) }
                            }
                        )
                    ) {
                        ForEach(AppUsagePeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .padding(.top, 8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("搜索应用", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    HStack {
                        Picker("排序", selection: $sortMode) {
                            ForEach(AppSortMode.allCases) { Text($0.title).tag($0) }
                        }
                        .frame(width: 125)
                        Picker("最小流量", selection: $minimumMB) {
                            Text("全部").tag(0.0)
                            Text("≥ 1 MB").tag(1.0)
                            Text("≥ 10 MB").tag(10.0)
                            Text("≥ 100 MB").tag(100.0)
                            Text("≥ 1 GB").tag(1024.0)
                        }
                        .frame(width: 125)
                    }
                }
            }
            .padding(24)

            Divider()

            if filteredApps.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            AppUsageRow(
                                app: app,
                                maximumBytes: filteredApps.map(\.totalBytes).max() ?? 1,
                                pid: livePID(for: app.appName)
                            )
                            Divider().padding(.leading, 70)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(DashboardBackground())
        .navigationTitle("应用")
        .task { await store.refreshAppPeriod() }
    }

    private func livePID(for name: String) -> Int32? {
        store.snapshot.processes.first { $0.processName == name }?.pid
    }
}

private enum AppSortMode: String, CaseIterable, Identifiable {
    case total, download, upload, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .total: "总流量"
        case .download: "下载"
        case .upload: "上传"
        case .name: "名称"
        }
    }
}

private struct AppUsageRow: View {
    let app: AppTrafficSummary
    let maximumBytes: Int64
    let pid: Int32?

    private var barRatio: Double {
        guard maximumBytes > 0 else { return 0 }
        return Double(app.totalBytes) / Double(maximumBytes)
    }

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(name: app.appName, pid: pid, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(app.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(TrafficByteFormatter.string(fromByteCount: app.totalBytes))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .indigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * barRatio)
                    }
                }
                .frame(height: 5)

                HStack(spacing: 16) {
                    Text("↓ \(TrafficByteFormatter.string(fromByteCount: app.receivedBytes))")
                        .foregroundStyle(.blue)
                    Text("↑ \(TrafficByteFormatter.string(fromByteCount: app.sentBytes))")
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct SettingsDashboard: View {
    @ObservedObject var store: TrafficMonitorStore
    var menuBarController: MenuBarStatusController?
    @State private var showResetConfirmation = false
    @AppStorage(PreferenceKey.menuBarDisplayMode) private var menuBarMode = MenuBarDisplayMode.liveRate.rawValue
    @AppStorage(PreferenceKey.dailyQuotaBytes) private var dailyQuotaGB = 0.0
    @AppStorage(PreferenceKey.weeklyQuotaBytes) private var weeklyQuotaGB = 0.0
    @AppStorage(PreferenceKey.monthlyQuotaBytes) private var monthlyQuotaGB = 0.0
    @AppStorage(PreferenceKey.billingDay) private var billingDay = 1
    @AppStorage(PreferenceKey.quotaWarningPercent) private var warningPercent = 80.0
    @AppStorage(PreferenceKey.quotaAlertsEnabled) private var quotaAlertsEnabled = false
    @AppStorage(PreferenceKey.showDockIcon) private var showInDock = true
    @AppStorage(PreferenceKey.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var currentNetworkQuotaGB = 0.0
    private let bytesPerGB = 1_073_741_824.0

    var body: some View {
        Form {
            Section("统计口径") {
                Picker(
                    "统计方式",
                    selection: Binding(
                        get: { store.accountingMode },
                        set: { store.setAccountingMode($0) }
                    )
                ) {
                    ForEach(TrafficAccountingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(store.accountingMode.explanation)
                    .font(.caption)
                    .foregroundStyle(store.accountingMode == .diagnostic ? .orange : .secondary)
            }

            Section("菜单栏") {
                Picker("显示内容", selection: $menuBarMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Toggle("在 Dock 中显示图标", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in
                        TrafficMonitorAppDelegate.applyDockIconPreference()
                    }

                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, visible in
                        menuBarController?.setMenuBarVisible(visible)
                    }
                Text("实时模式以两行分别显示下载和上传；也可以显示今日、本月或配额剩余。关闭后统计仍会在后台运行，可通过 Dock 或此窗口查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("流量配额") {
                quotaRow("每日", value: $dailyQuotaGB)
                quotaRow("每周", value: $weeklyQuotaGB)
                quotaRow("账单周期", value: $monthlyQuotaGB)
                Stepper("每月 \(billingDay) 日重置", value: $billingDay, in: 1...28)
                HStack(spacing: 12) {
                    Text("达到阈值")
                    Slider(value: $warningPercent, in: 50...100, step: 5)
                    Text("\(Int(warningPercent))%")
                        .monospacedDigit()
                        .frame(minWidth: 42, alignment: .trailing)
                }
                Toggle("达到配额阈值时发送通知", isOn: $quotaAlertsEnabled)
                    .onChange(of: quotaAlertsEnabled) { _, enabled in
                        if enabled { Task { _ = await QuotaNotifications.requestPermission() } }
                    }
                Text("填 0 表示不限制。当前账单周期已使用 \(TrafficByteFormatter.string(fromByteCount: store.billingCycleTotals.totalBytes))。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("\(store.currentNetworkName) 配额") {
                    HStack(spacing: 8) {
                        TextField("不限制", value: $currentNetworkQuotaGB, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("GB")
                            .foregroundStyle(.secondary)
                        Button("保存") {
                            NetworkQuotaPreferences.setQuota(
                                Int64(max(0, currentNetworkQuotaGB) * bytesPerGB),
                                for: store.currentNetworkName
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }

            Section("采集") {
                LabeledContent("采集引擎", value: "macOS nettop")
                LabeledContent("采样间隔", value: "2 秒")
                LabeledContent("历史精度", value: "每分钟")
                LabeledContent("应用归属", value: "合并 Helper · 代理去重")
                LabeledContent(
                    "状态",
                    value: store.errorMessage == nil ? "正在监控" : "采集异常"
                )
                LabeledContent("当前网络", value: store.currentNetworkName)
                Button("允许识别具体 Wi-Fi 名称") {
                    store.requestWiFiNameAccess()
                }
                Text("macOS 将读取 Wi-Fi 名称视为位置相关信息；授权只用于在本机区分网络配额。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私与存储") {
                Label(
                    "流量数据只保存在这台 Mac 上，不会上传到任何服务器。",
                    systemImage: "lock.shield"
                )
                Text("~/Library/Application Support/TrafficMonitor/traffic.sqlite")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button("清除全部历史数据", role: .destructive) {
                    showResetConfirmation = true
                }
            }

            Section("当前版本") {
                LabeledContent("版本", value: applicationVersion)
                Text("当前版本提供实时监控、本地历史、流量配额与网络质量分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear {
            currentNetworkQuotaGB = Double(
                NetworkQuotaPreferences.quotas()[store.currentNetworkName] ?? 0
            ) / bytesPerGB
        }
        .confirmationDialog(
            "确定清除所有历史流量数据？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除历史数据", role: .destructive) {
                Task { await store.resetHistory() }
            }
        } message: {
            Text("此操作无法撤销，实时监控不会受到影响。")
        }
    }

    private var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func quotaRow(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("不限制", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("GB")
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 4)
        }
    }
}

private struct DashboardCard<Content: View>: View {
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

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.045), .clear, Color.indigo.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct CompactAnomalyCard: View {
    let anomalies: [UploadAnomaly]
    var body: some View {
        DashboardCard {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.title2).foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现 \(anomalies.count) 个上传异常").font(.headline)
                    Text(anomalies.prefix(3).map { "\($0.appName) · \(TrafficByteFormatter.string(fromByteCount: $0.todaySentBytes))" }.joined(separator: "    "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
    }
}

private struct HistoryErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
