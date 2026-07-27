import Charts
import SwiftUI

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct MiniChart: View {
    let points: [ChartPoint]
    let color: Color

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Minimum", 0),
                yEnd: .value("Value", point.value)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [color.opacity(0.28), color.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
        .accessibilityLabel("Last 60 seconds")
    }

    private var xDomain: ClosedRange<Date> {
        let end = points.last?.date ?? .now
        let start = points.first?.date ?? end.addingTimeInterval(-60)
        return start...max(end, start.addingTimeInterval(1))
    }
}
