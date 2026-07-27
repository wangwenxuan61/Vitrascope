import Combine
import Foundation

private actor MetricsSampler {
    private var cpuCollector = CPUCollector()
    private var memoryCollector = MemoryCollector()
    private var gpuCollector = GPUCollector()
    private var smcCollector = SMCCollector()
    private var hidTemperatureCollector = HIDTemperatureCollector()

    func sample() -> SystemSnapshot {
        let smc = smcCollector.collect()
        let temperatures = Self.mergedTemperatures(
            smc: smc.temperatures,
            hidCPU: hidTemperatureCollector.collect()
        )
        return SystemSnapshot(
            timestamp: .now,
            cpu: cpuCollector.collect(),
            memory: memoryCollector.collect(),
            gpuPercent: gpuCollector.collect(),
            thermalState: Self.thermalState(),
            temperatures: temperatures,
            fans: smc.fans
        )
    }

    private static func mergedTemperatures(
        smc: SensorAvailability<[TemperatureReading]>,
        hidCPU: SensorAvailability<Double>
    ) -> SensorAvailability<[TemperatureReading]> {
        if case .available(let smcReadings) = smc,
           smcReadings.contains(where: { $0.id == "cpu" }) {
            return smc
        }

        guard case .available(let cpuTemperature) = hidCPU else {
            return smc
        }
        let cpu = TemperatureReading(id: "cpu", label: "CPU", celsius: cpuTemperature)

        if case .available(let smcReadings) = smc {
            return .available([cpu] + smcReadings.filter { $0.id != "cpu" })
        }
        return .available([cpu])
    }

    private static func thermalState() -> SystemThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.empty
    @Published private(set) var history: [SystemSnapshot] = []

    private let sampler = MetricsSampler()
    private var historyBuffer = FixedRingBuffer<SystemSnapshot>(capacity: 60)
    private var samplingTask: Task<Void, Never>?

    init() {
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let newSnapshot = await sampler.sample()
                update(with: newSnapshot)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        samplingTask?.cancel()
    }

    private func update(with newSnapshot: SystemSnapshot) {
        snapshot = newSnapshot
        historyBuffer.append(newSnapshot)
        history = historyBuffer.elements
    }
}
