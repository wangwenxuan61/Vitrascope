import SwiftUI

struct CPUCard: View {
    let reading: SensorAvailability<CPUReading>
    let temperature: SensorAvailability<TemperatureReading>
    let processes: SensorAvailability<[ProcessResourceReading]>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(title: "CPU", systemImage: "cpu", accent: .blue) {
            switch reading {
            case .available(let cpu):
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormatting.percent(cpu.totalPercent))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    cpuTemperature
                }

                HStack(spacing: 10) {
                    StatLabel(label: "User", value: MetricFormatting.percent(cpu.userPercent))
                    StatLabel(label: "System", value: MetricFormatting.percent(cpu.systemPercent))
                    Spacer()
                }
                MiniChart(points: cpuPoints, color: .blue)
                TopProcessList(readings: processes, metric: .cpu)
            case .unavailable(let message):
                UnavailableReadingView(message: message)
            }
        }
    }

    private var cpuPoints: [ChartPoint] {
        history.compactMap { snapshot in
            guard case .available(let value) = snapshot.cpu else { return nil }
            return ChartPoint(date: snapshot.timestamp, value: value.totalPercent)
        }
    }

    @ViewBuilder
    private var cpuTemperature: some View {
        VStack(alignment: .trailing, spacing: 1) {
            switch temperature {
            case .available(let reading):
                Text(MetricFormatting.temperature(reading.celsius))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.blue)
                    .monospacedDigit()
                Text(reading.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Unavailable")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Processor Temperature")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MemoryCard: View {
    let reading: SensorAvailability<MemoryReading>
    let processes: SensorAvailability<[ProcessResourceReading]>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(
            title: "Memory",
            systemImage: "memorychip",
            accent: Color(red: 0.22, green: 0.56, blue: 0.86)
        ) {
            switch reading {
            case .available(let memory):
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormatting.percent(memory.usagePercent))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        StatLabel(
                            label: "Used",
                            value: "\(MetricFormatting.bytes(memory.usedBytes)) / \(MetricFormatting.bytes(memory.totalBytes))"
                        )
                        StatLabel(label: "Swap", value: MetricFormatting.bytes(memory.swapUsedBytes))
                    }
                }

                MiniChart(points: memoryPoints, color: .blue)
                TopProcessList(readings: processes, metric: .memory)
            case .unavailable(let message):
                UnavailableReadingView(message: message)
            }
        }
    }

    private var memoryPoints: [ChartPoint] {
        history.compactMap { snapshot in
            guard case .available(let value) = snapshot.memory else { return nil }
            return ChartPoint(date: snapshot.timestamp, value: value.usagePercent)
        }
    }
}

private enum ProcessDisplayMetric {
    case cpu
    case memory
}

private struct TopProcessList: View {
    let readings: SensorAvailability<[ProcessResourceReading]>
    let metric: ProcessDisplayMetric

    var body: some View {
        Divider().opacity(0.35)

        Text("Top Processes")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

        switch readings {
        case .available(let processes):
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    Text(process.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(value(for: process))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
            }
        case .unavailable(let message):
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func value(for process: ProcessResourceReading) -> String {
        switch metric {
        case .cpu:
            MetricFormatting.processPercent(process.cpuPercent)
        case .memory:
            MetricFormatting.bytes(process.memoryBytes)
        }
    }
}

struct GPUCard: View {
    let reading: SensorAvailability<Double>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(
            title: "GPU",
            systemImage: "square.3.layers.3d",
            accent: Color(red: 0.40, green: 0.47, blue: 0.70)
        ) {
            switch reading {
            case .available(let percent):
                Text(MetricFormatting.percent(percent))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                MiniChart(points: gpuPoints, color: .indigo)
            case .unavailable(let message):
                UnavailableReadingView(message: message)
            }
        }
    }

    private var gpuPoints: [ChartPoint] {
        history.compactMap { snapshot in
            guard case .available(let value) = snapshot.gpuPercent else { return nil }
            return ChartPoint(date: snapshot.timestamp, value: value)
        }
    }
}

struct ThermalCard: View {
    let thermalState: SystemThermalState
    let temperatures: SensorAvailability<[TemperatureReading]>
    let fans: SensorAvailability<[FanReading]>

    var body: some View {
        MetricCard(
            title: "Thermal & Fans",
            systemImage: "thermometer.medium",
            accent: Color(red: 0.31, green: 0.62, blue: 0.55)
        ) {
            HStack {
                Text("System")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(thermalState.rawValue)
                    .fontWeight(.semibold)
                    .foregroundStyle(thermalColor)
            }
            .font(.system(size: 12))

            Divider().opacity(0.35)

            HStack(alignment: .top, spacing: 16) {
                temperatureColumn

                Divider().opacity(0.35)

                fanColumn
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private var thermalColor: Color {
        switch thermalState {
        case .nominal: .mint
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    @ViewBuilder
    private var temperatureColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Temperature")
                .foregroundStyle(.secondary)
            switch temperatures {
            case .available(let readings):
                ForEach(readings) { reading in
                    HStack {
                        Text(reading.label)
                        Spacer()
                        Text(MetricFormatting.temperature(reading.celsius))
                            .monospacedDigit()
                    }
                }
            case .unavailable:
                Text("Unavailable")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fanColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fans")
                .foregroundStyle(.secondary)
            switch fans {
            case .available(let readings):
                ForEach(readings) { fan in
                    HStack {
                        Text("Fan \(fan.id + 1)")
                        Spacer()
                        Text(MetricFormatting.rpm(fan.rpm))
                            .monospacedDigit()
                    }
                }
            case .unavailable:
                Text("Unavailable")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
