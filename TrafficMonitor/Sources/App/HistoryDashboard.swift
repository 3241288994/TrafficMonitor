import AppKit
import Charts
import SwiftUI
import TrafficCore

private enum HistoryPreset: String, CaseIterable, Identifiable {
    case today = "今天"
    case sevenDays = "7 天"
    case thirtyDays = "30 天"
    case thisMonth = "本月"
    case lastMonth = "上月"
    case custom = "自定义"

    var id: String { rawValue }
}

struct HistoryDashboard: View {
    @ObservedObject var store: TrafficMonitorStore
    @State private var preset: HistoryPreset = .thirtyDays
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var aggregation: TrafficAggregation = .day
    @State private var exportFormat: TrafficExportFormat = .csv
    @State private var exportMessage: String?
    @State private var hoveredPoint: TrafficHistoryPoint?

    private var range: DateInterval {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch preset {
        case .today:
            return DateInterval(start: today, end: now)
        case .sevenDays:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -6, to: today) ?? today,
                end: now
            )
        case .thirtyDays:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -29, to: today) ?? today,
                end: now
            )
        case .thisMonth:
            return DateInterval(
                start: calendar.dateInterval(of: .month, for: now)?.start ?? today,
                end: now
            )
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                if let message = exportMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("导出失败") ? .red : .secondary)
                }
                summary
                historyChart
                heatmap
                ranking
            }
            .padding(24)
        }
        .background(DashboardBackground())
        .navigationTitle("历史")
        .task { await reload() }
        .onChange(of: preset) { _, _ in Task { await reload() } }
        .onChange(of: aggregation) { _, _ in Task { await reload() } }
        .onChange(of: store.accountingMode) { _, _ in Task { await reload() } }
        .onChange(of: customStart) { _, _ in if preset == .custom { Task { await reload() } } }
        .onChange(of: customEnd) { _, _ in if preset == .custom { Task { await reload() } } }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("历史与分析")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("自选时间范围、趋势、使用热力图与数据导出")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("格式", selection: $exportFormat) {
                ForEach(TrafficExportFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 90)
            Button("导出", systemImage: "square.and.arrow.up") {
                Task { await export() }
            }
            .fixedSize()
        }
    }

    private var controls: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("范围", selection: $preset) {
                    ForEach(HistoryPreset.allCases) { Text($0.rawValue).tag($0) }
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

    private var summary: some View {
        HStack(spacing: 12) {
            HistoryMetric(title: "总流量", value: store.selectedRangeTotals.totalBytes, tint: .indigo)
            HistoryMetric(title: "下载", value: store.selectedRangeTotals.receivedBytes, tint: .blue)
            HistoryMetric(title: "上传", value: store.selectedRangeTotals.sentBytes, tint: .orange)
            HistoryMetric(title: "活跃应用", text: "\(store.selectedRangeApps.count)", tint: .green)
        }
    }

    private var historyChart: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("流量趋势").font(.headline)
                if store.historyPoints.isEmpty {
                    ContentUnavailableView("暂无数据", systemImage: "chart.xyaxis.line")
                        .frame(height: 220)
                } else {
                    Chart(store.historyPoints) { point in
                        AreaMark(x: .value("时间", point.start), y: .value("总流量", point.totalBytes))
                            .foregroundStyle(.blue.opacity(0.12))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("时间", point.start), y: .value("下载", point.receivedBytes))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("时间", point.start), y: .value("上传", point.sentBytes))
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)

                        if hoveredPoint?.id == point.id {
                            RuleMark(x: .value("选中时间", point.start))
                                .foregroundStyle(.secondary.opacity(0.4))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 8) {
                                    TrafficChartTooltip(
                                        title: historyPointTitle(point.start),
                                        received: point.receivedBytes,
                                        sent: point.sentBytes
                                    )
                                }
                        }
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
                    .frame(height: 260)
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
                                        hoveredPoint = store.historyPoints.min {
                                            abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
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

    private var heatmap: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("星期 × 小时热力图").font(.headline)
                Text("颜色越深，表示该时段累计流量越高。")
                    .font(.caption).foregroundStyle(.secondary)
                HourlyHeatmapView(cells: store.heatmapCells)
            }
        }
    }

    private var ranking: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("该范围内流量最多的应用").font(.headline)
                ForEach(store.selectedRangeApps.prefix(12)) { app in
                    HStack {
                        AppIconView(name: app.appName, pid: nil, size: 26)
                        Text(app.appName).lineLimit(1)
                        Spacer()
                        Text(TrafficByteFormatter.string(fromByteCount: app.totalBytes))
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }

    private func historyPointTitle(_ date: Date) -> String {
        switch aggregation {
        case .minute:
            date.formatted(.dateTime.month().day().hour().minute())
        case .hour:
            date.formatted(.dateTime.month().day().hour())
        case .day:
            date.formatted(.dateTime.year().month().day().weekday(.wide))
        case .month:
            date.formatted(.dateTime.year().month(.wide))
        }
    }

    private func reload() async {
        await store.loadHistory(from: range.start, to: range.end, aggregation: aggregation)
    }

    @MainActor
    private func export() async {
        do {
            let data = try await store.exportData(
                from: range.start,
                to: range.end,
                aggregation: aggregation,
                format: exportFormat
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = exportFormat == .csv ? [.commaSeparatedText] : [.json]
            panel.nameFieldStringValue = "TrafficMonitor-\(Date.now.formatted(.iso8601.year().month().day())).\(exportFormat.rawValue)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            exportMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct HistoryMetric: View {
    let title: String
    let text: String
    let tint: Color

    init(title: String, value: Int64, tint: Color) {
        self.title = title
        self.text = TrafficByteFormatter.string(fromByteCount: value)
        self.tint = tint
    }

    init(title: String, text: String, tint: Color) {
        self.title = title
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(text).font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
    }
}

private struct HourlyHeatmapView: View {
    let cells: [HourlyHeatmapCell]
    @State private var hoveredCell: HourlyHeatmapCell?
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private var maximum: Double { Double(max(cells.map(\.totalBytes).max() ?? 0, 1)) }

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Color.clear.frame(width: 24, height: 13)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(1...7, id: \.self) { weekday in
                GridRow {
                    Text(weekdays[weekday - 1]).font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<24, id: \.self) { hour in
                        let cell = cells.first { $0.weekday == weekday && $0.hour == hour }
                        let ratio = Double(cell?.totalBytes ?? 0) / maximum
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.08 + ratio * 0.88))
                            .frame(minWidth: 12, maxWidth: .infinity, minHeight: 18)
                            .overlay {
                                if hoveredCell?.id == cell?.id {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(.white.opacity(0.9), lineWidth: 1.5)
                                }
                            }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active:
                                    hoveredCell = cell
                                case .ended:
                                    if hoveredCell?.id == cell?.id { hoveredCell = nil }
                                }
                            }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let cell = hoveredCell {
                HeatmapTooltip(
                    weekday: weekdays[cell.weekday - 1],
                    hour: cell.hour,
                    received: cell.receivedBytes,
                    sent: cell.sentBytes
                )
                .offset(y: -54)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct HistoryCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.7) }
            .shadow(color: .black.opacity(0.045), radius: 10, y: 3)
    }
}
