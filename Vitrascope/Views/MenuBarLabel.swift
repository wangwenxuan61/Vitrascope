import SwiftUI

struct MenuBarLabel: View {
    let snapshot: SystemSnapshot
    let metric: MetricKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
                .symbolRenderingMode(.hierarchical)

            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var value: String? {
        switch metric {
        case .cpu:
            snapshot.cpu.value.map { MetricFormatting.percent($0.totalPercent) }
        case .memory:
            snapshot.memory.value.map { MetricFormatting.percent($0.usagePercent) }
        case .gpu:
            snapshot.gpuPercent.value.map(MetricFormatting.percent)
        case .temperature:
            snapshot.cpuTemperature.value.map(MetricFormatting.temperature)
        case .iconOnly:
            nil
        }
    }

    private var accessibilityText: String {
        value.map { "Vitrascope, \(metric.title) \($0)" } ?? "Vitrascope"
    }
}
