import Combine
import Foundation

private actor MetricsSampler {
    private var cpuCollector = CPUCollector()
    private var memoryCollector = MemoryCollector()
    private var gpuCollector = GPUCollector()
    private var smcCollector = SMCCollector()
    private var hidTemperatureCollector = HIDTemperatureCollector()
    private var processCollector = ProcessCollector()
    private var latestProcessMetrics = ProcessMetricsSnapshot.empty
    private var sampleCount = 0

    func sample() -> (system: SystemSnapshot, processes: ProcessMetricsSnapshot) {
        let smc = smcCollector.collect()
        let temperatures = Self.mergedTemperatures(
            smc: smc.temperatures,
            hid: hidTemperatureCollector.collect()
        )
        if sampleCount.isMultiple(of: 2) {
            latestProcessMetrics = processCollector.collect()
        }
        sampleCount += 1

        let system = SystemSnapshot(
            timestamp: .now,
            cpu: cpuCollector.collect(),
            memory: memoryCollector.collect(),
            gpuPercent: gpuCollector.collect(),
            thermalState: Self.thermalState(),
            temperatures: temperatures,
            fans: smc.fans
        )
        return (system, latestProcessMetrics)
    }

    private static func mergedTemperatures(
        smc: SensorAvailability<[TemperatureReading]>,
        hid: SensorAvailability<[TemperatureReading]>
    ) -> SensorAvailability<[TemperatureReading]> {
        switch (smc, hid) {
        case (.available(let smcReadings), .available(let hidReadings)):
            let smcIDs = Set(smcReadings.map(\.id))
            return .available(
                smcReadings + hidReadings.filter { !smcIDs.contains($0.id) }
            )
        case (.available, _):
            return smc
        case (_, .available):
            return hid
        case (.unavailable(let message), .unavailable):
            return .unavailable(message)
        }
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
    @Published private(set) var processes = ProcessMetricsSnapshot.empty
    @Published private(set) var history: [SystemSnapshot] = []

    private let sampler = MetricsSampler()
    private var historyBuffer = FixedRingBuffer<SystemSnapshot>(capacity: 60)
    private var samplingTask: Task<Void, Never>?

    init() {
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = await sampler.sample()
                update(with: sample.system, processes: sample.processes)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        samplingTask?.cancel()
    }

    private func update(
        with newSnapshot: SystemSnapshot,
        processes newProcesses: ProcessMetricsSnapshot
    ) {
        snapshot = newSnapshot
        processes = newProcesses
        historyBuffer.append(newSnapshot)
        history = historyBuffer.elements
    }
}
