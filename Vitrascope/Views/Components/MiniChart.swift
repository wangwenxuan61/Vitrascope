import Charts
import SwiftUI

struct MiniChart: View {
    let points: [MetricSample]
    let color: Color

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
        .accessibilityLabel("Recent usage")
    }

    private var xDomain: ClosedRange<Date> {
        let end = points.last?.timestamp ?? .now
        let start = points.first?.timestamp ?? end.addingTimeInterval(-60)
        return start...max(end, start.addingTimeInterval(1))
    }
}
