import SwiftUI
import Charts
import SolplanetEnergyTrackerLib

/// History chart for one metric over a selectable window (plan §8). Line breaks
/// across gaps are preserved by drawing each contiguous run as its own `series`,
/// so downtime shows a hole instead of a bridged line.
struct EnergyHistoryChartView: View {
    let reader: HistoryReader

    @State private var metric: ChartMetric = .pv
    @State private var window: ChartWindow = .day
    @State private var points: [ChartPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Metric", selection: $metric) {
                ForEach(ChartMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            chart

            Picker("Window", selection: $window) {
                ForEach(ChartWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .onAppear(perform: reload)
        .onChange(of: metric) { _, _ in reload() }
        .onChange(of: window) { _, _ in reload() }
    }

    @ViewBuilder
    private var chart: some View {
        if points.compactMap(\.value).isEmpty {
            Text("No history yet for this window.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(height: 160, alignment: .center)
                .frame(maxWidth: .infinity)
        } else {
            Chart(segmentedPoints, id: \.point.id) { item in
                if let value = item.point.value {
                    LineMark(
                        x: .value("Time", item.point.date),
                        y: .value(metric.title, value),
                        series: .value("Segment", item.segment)
                    )
                    .interpolationMethod(.monotone)
                }
            }
            .frame(height: 160)
        }
    }

    /// Tags each non-nil point with a segment index that increments at every gap
    /// marker, so `LineMark(series:)` draws separate, non-bridged lines.
    private var segmentedPoints: [(point: ChartPoint, segment: Int)] {
        var result: [(ChartPoint, Int)] = []
        var segment = 0
        for point in points {
            if point.value == nil {
                segment += 1
            } else {
                result.append((point, segment))
            }
        }
        return result.map { (point: $0.0, segment: $0.1) }
    }

    private func reload() {
        let now = Date()
        let lowerBound = window.seconds.map { now.addingTimeInterval(-$0) } ?? Date.distantPast
        let snapshots = reader.snapshots(from: lowerBound, to: now)
        points = ChartSeriesResolver.series(from: snapshots, metric: metric, window: window, now: now)
    }
}
