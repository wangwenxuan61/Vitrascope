import Foundation

enum SensorAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(String)

    var value: Value? {
        guard case .available(let value) = self else { return nil }
        return value
    }
}

enum MetricKind: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case temperature
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .temperature: "Temperature"
        case .iconOnly: "Icon Only"
        }
    }
}

struct CPUReading: Equatable, Sendable {
    let totalPercent: Double
    let userPercent: Double
    let systemPercent: Double
}

struct MemoryReading: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let swapUsedBytes: UInt64

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes) * 100, 0), 100)
    }
}

struct FanReading: Equatable, Sendable, Identifiable {
    let id: Int
    let rpm: Double
}

struct TemperatureReading: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let celsius: Double
}

enum SystemThermalState: String, Equatable, Sendable {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
    case unknown = "Unknown"
}

struct SystemSnapshot: Equatable, Sendable, Identifiable {
    let timestamp: Date
    let cpu: SensorAvailability<CPUReading>
    let memory: SensorAvailability<MemoryReading>
    let gpuPercent: SensorAvailability<Double>
    let thermalState: SystemThermalState
    let temperatures: SensorAvailability<[TemperatureReading]>
    let fans: SensorAvailability<[FanReading]>

    var id: Date { timestamp }

    static let empty = SystemSnapshot(
        timestamp: .now,
        cpu: .unavailable("Collecting"),
        memory: .unavailable("Collecting"),
        gpuPercent: .unavailable("Collecting"),
        thermalState: .unknown,
        temperatures: .unavailable("Collecting"),
        fans: .unavailable("Collecting")
    )
}
