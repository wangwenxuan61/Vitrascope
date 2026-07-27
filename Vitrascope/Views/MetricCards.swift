import SwiftUI

struct CPUCard: View {
    let reading: SensorAvailability<CPUReading>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(title: "CPU", systemImage: "cpu", accent: .cyan) {
            switch reading {
            case .available(let cpu):
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormatting.percent(cpu.totalPercent))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    HStack(spacing: 10) {
                        StatLabel(label: "User", value: MetricFormatting.percent(cpu.userPercent))
                        StatLabel(label: "System", value: MetricFormatting.percent(cpu.systemPercent))
                    }
                }

                MiniChart(points: cpuPoints, color: .cyan)
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
}

struct MemoryCard: View {
    let reading: SensorAvailability<MemoryReading>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(title: "Memory", systemImage: "memorychip", accent: .blue) {
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

struct GPUCard: View {
    let reading: SensorAvailability<Double>
    let history: [SystemSnapshot]

    var body: some View {
        MetricCard(title: "GPU", systemImage: "square.3.layers.3d", accent: .indigo) {
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
        MetricCard(title: "Thermal & Fans", systemImage: "thermometer.medium", accent: .mint) {
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
