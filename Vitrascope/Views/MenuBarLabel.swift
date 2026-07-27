import SwiftUI

struct MenuBarLabel: View {
    let snapshot: SystemSnapshot
    let metric: MetricKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18, alignment: .center)

            if metric != .iconOnly {
                Text(verbatim: displayText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 45, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityText)
    }

    private var displayValue: String? {
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

    private var displayText: String {
        Self.fixedText(for: displayValue)
    }

    static func fixedText(for value: String?) -> String {
        fixedColumns(for: value)
            .map { $0.isEmpty ? " " : $0 }
            .joined()
    }

    static func fixedColumns(for value: String?) -> [String] {
        guard let value else {
            return ["", "—", "", "", ""]
        }

        let number: String
        let unit: String
        if value.hasSuffix("°C") {
            number = String(value.dropLast(2))
            unit = "°C"
        } else if value.hasSuffix("%") {
            number = String(value.dropLast())
            unit = "%"
        } else {
            number = value
            unit = ""
        }

        let numberCharacters = Array(number.suffix(3)).map(String.init)
        let unitCharacters = Array(unit.prefix(2)).map(String.init)
        let numberPadding = Array(repeating: "", count: 3 - numberCharacters.count)
        let unitPadding = Array(repeating: "", count: 2 - unitCharacters.count)
        return numberPadding + numberCharacters + unitCharacters + unitPadding
    }

    private var accessibilityText: String {
        let value: String?
        switch metric {
        case .cpu:
            value = snapshot.cpu.value.map { MetricFormatting.percent($0.totalPercent) }
        case .memory:
            value = snapshot.memory.value.map { MetricFormatting.percent($0.usagePercent) }
        case .gpu:
            value = snapshot.gpuPercent.value.map(MetricFormatting.percent)
        case .temperature:
            value = snapshot.cpuTemperature.value.map(MetricFormatting.temperature)
        case .iconOnly:
            value = nil
        }
        return value.map { "Vitrascope, \(metric.title) \($0)" } ?? "Vitrascope"
    }
}
