import Foundation

/// Turns recorded `PowerSnapshot`s into a gap-aware series for one metric over a
/// time window. Pure → unit tested. Two things break a line: a `nil` metric value
/// (e.g. grid with no meter) and a time gap larger than `maxGap` (the app was off,
/// so we must not draw a straight line across hours of missing data).
public enum ChartSeriesResolver {
    /// Beyond this gap between consecutive samples, insert a break so the chart
    /// shows a hole rather than interpolating across downtime.
    public static let defaultMaxGap: TimeInterval = 15 * 60

    public static func series(
        from snapshots: [PowerSnapshot],
        metric: ChartMetric,
        window: ChartWindow,
        now: Date = Date(),
        maxGap: TimeInterval = ChartSeriesResolver.defaultMaxGap
    ) -> [ChartPoint] {
        let lowerBound = window.seconds.map { now.addingTimeInterval(-$0) }

        // Decode timestamps once, keep only the in-window samples, in time order.
        let dated: [(date: Date, snapshot: PowerSnapshot)] = snapshots.compactMap { snapshot in
            guard let date = ISODate(snapshot.t).date else { return nil }
            if let lowerBound, date < lowerBound { return nil }
            if date > now { return nil }
            return (date, snapshot)
        }.sorted { $0.date < $1.date }

        var points: [ChartPoint] = []
        var nextID = 0
        var previousDate: Date?

        for entry in dated {
            if let previousDate, entry.date.timeIntervalSince(previousDate) > maxGap {
                // Insert a break midway so the gap is visible.
                points.append(ChartPoint(id: nextID, date: previousDate.addingTimeInterval(maxGap / 2), value: nil))
                nextID += 1
            }
            points.append(ChartPoint(id: nextID, date: entry.date, value: metric.value(from: entry.snapshot)))
            nextID += 1
            previousDate = entry.date
        }
        return points
    }
}
