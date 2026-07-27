import Combine
import Foundation

struct SamplingRequest: OptionSet, Sendable {
    let rawValue: UInt8

    static let cpu = SamplingRequest(rawValue: 1 << 0)
    static let memory = SamplingRequest(rawValue: 1 << 1)
    static let gpu = SamplingRequest(rawValue: 1 << 2)
    static let thermal = SamplingRequest(rawValue: 1 << 3)
    static let processes = SamplingRequest(rawValue: 1 << 4)
    static let all: SamplingRequest = [.cpu, .memory, .gpu, .thermal, .processes]
}

enum SamplingMetric: CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case gpu
    case thermal
    case processes

    var request: SamplingRequest {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .thermal: .thermal
        case .processes: .processes
        }
    }
}

struct SamplingProfile: Equatable, Sendable {
    let intervals: [SamplingMetric: TimeInterval]

    static func profile(panelVisible: Bool, menuMetric: MetricKind) -> SamplingProfile {
        if panelVisible {
            return SamplingProfile(intervals: [
                .cpu: 1,
                .memory: 2,
                .gpu: 2,
                .thermal: 5,
                .processes: 2
            ])
        }

        switch menuMetric {
        case .cpu:
            return SamplingProfile(intervals: [.cpu: 1])
        case .memory:
            return SamplingProfile(intervals: [.memory: 2])
        case .gpu:
            return SamplingProfile(intervals: [.gpu: 2])
        case .temperature:
            return SamplingProfile(intervals: [.thermal: 5])
        case .iconOnly:
            return SamplingProfile(intervals: [:])
        }
    }
}

private struct MetricsSample: Sendable {
    let timestamp: Date
    let cpu: SensorAvailability<CPUReading>?
    let memory: SensorAvailability<MemoryReading>?
    let gpu: SensorAvailability<Double>?
    let temperatures: SensorAvailability<[TemperatureReading]>?
    let fans: SensorAvailability<[FanReading]>?
    let processes: ProcessMetricsSnapshot?
}

private actor MetricsSampler {
    private var cpuCollector = CPUCollector()
    private var memoryCollector = MemoryCollector()
    private var gpuCollector = GPUCollector()
    private var smcCollector = SMCCollector()
    private var hidTemperatureCollector = HIDTemperatureCollector()
    private var processCollector = ProcessCollector()

    func sample(_ request: SamplingRequest) -> MetricsSample {
        var temperatures: SensorAvailability<[TemperatureReading]>?
        var fans: SensorAvailability<[FanReading]>?
        if request.contains(.thermal) {
            let smc = smcCollector.collect()
            let hidCPU: SensorAvailability<Double>
            if Self.hasCPUTemperature(smc.temperatures) {
                hidCPU = .unavailable("SMC temperature available")
            } else {
                hidCPU = hidTemperatureCollector.collect()
            }
            temperatures = Self.mergedTemperatures(smc: smc.temperatures, hidCPU: hidCPU)
            fans = smc.fans
        }

        return MetricsSample(
            timestamp: .now,
            cpu: request.contains(.cpu) ? cpuCollector.collect() : nil,
            memory: request.contains(.memory) ? memoryCollector.collect() : nil,
            gpu: request.contains(.gpu) ? gpuCollector.collect() : nil,
            temperatures: temperatures,
            fans: fans,
            processes: request.contains(.processes) ? processCollector.collect() : nil
        )
    }

    private static func hasCPUTemperature(
        _ temperatures: SensorAvailability<[TemperatureReading]>
    ) -> Bool {
        guard case .available(let readings) = temperatures else { return false }
        return readings.contains(where: { $0.id == "cpu" })
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

}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var state: MonitorState

    var snapshot: SystemSnapshot { state.snapshot }
    var history: MetricHistory { state.history }
    var processes: ProcessMetricsSnapshot { state.processes }

    private let sampler = MetricsSampler()
    private var latestSnapshot: SystemSnapshot
    private var cpuHistory = FixedRingBuffer<MetricSample>(capacity: 30)
    private var memoryHistory = FixedRingBuffer<MetricSample>(capacity: 30)
    private var gpuHistory = FixedRingBuffer<MetricSample>(capacity: 30)
    private var latestHistory = MetricHistory.empty
    private var latestProcesses = ProcessMetricsSnapshot.empty
    private var lastHistoryUpdate: [SamplingMetric: Date] = [:]
    private var lastSample: [SamplingMetric: Date] = [:]
    private var samplingTask: Task<Void, Never>?
    private var thermalStateCancellable: AnyCancellable?
    private var panelVisible = false
    private var menuMetric: MetricKind

    init() {
        menuMetric = UserDefaults.standard.string(forKey: "menuBarMetric")
            .flatMap(MetricKind.init(rawValue:)) ?? .cpu

        let initialSnapshot = Self.snapshotWithCurrentThermalState(SystemSnapshot.empty)
        latestSnapshot = initialSnapshot
        state = MonitorState(
            snapshot: initialSnapshot,
            history: .empty,
            processes: .empty
        )

        thermalStateCancellable = NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.thermalStateDidChange()
            }
        }

        restartSampling(force: requestForCurrentProfile())
    }

    deinit {
        samplingTask?.cancel()
    }

    func setPanelVisible(_ isVisible: Bool) {
        guard panelVisible != isVisible else { return }
        panelVisible = isVisible
        restartSampling(force: isVisible ? .all : [])
    }

    func setMenuMetric(_ metric: MetricKind) {
        guard menuMetric != metric else { return }
        menuMetric = metric

        if !panelVisible {
            publishLatestSnapshot()
            restartSampling(force: requestForCurrentProfile())
        }
    }

    private func restartSampling(force: SamplingRequest) {
        samplingTask?.cancel()
        let profile = currentProfile
        guard !profile.intervals.isEmpty else {
            samplingTask = nil
            return
        }

        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop(initialRequest: force)
        }
    }

    private func runSamplingLoop(initialRequest: SamplingRequest) async {
        var forcedRequest = initialRequest

        while !Task.isCancelled {
            let profile = currentProfile
            guard !profile.intervals.isEmpty else { return }

            let now = Date()
            var request = forcedRequest
            forcedRequest = []

            for (metric, interval) in profile.intervals {
                guard let lastSample = lastSample[metric] else {
                    request.formUnion(metric.request)
                    continue
                }
                if now.timeIntervalSince(lastSample) >= interval {
                    request.formUnion(metric.request)
                }
            }

            if !request.isEmpty {
                let sample = await sampler.sample(request)
                guard !Task.isCancelled else { return }
                recordSampleDates(for: request, at: sample.timestamp)
                update(with: sample)
                continue
            }

            let delay = profile.intervals.compactMap { metric, interval -> TimeInterval? in
                guard let sampledAt = lastSample[metric] else { return 0 }
                return max(interval - now.timeIntervalSince(sampledAt), 0)
            }.min() ?? 1

            do {
                try await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .seconds(max(delay * 0.1, 0.05)),
                    clock: .continuous
                )
            } catch {
                return
            }
        }
    }

    private var currentProfile: SamplingProfile {
        SamplingProfile.profile(panelVisible: panelVisible, menuMetric: menuMetric)
    }

    private func requestForCurrentProfile() -> SamplingRequest {
        currentProfile.intervals.keys.reduce(into: SamplingRequest()) { request, metric in
            request.formUnion(metric.request)
        }
    }

    private func recordSampleDates(for request: SamplingRequest, at date: Date) {
        for metric in SamplingMetric.allCases where request.contains(metric.request) {
            lastSample[metric] = date
        }
    }

    private func update(with sample: MetricsSample) {
        let oldSnapshot = latestSnapshot
        latestSnapshot = SystemSnapshot(
            timestamp: sample.timestamp,
            cpu: sample.cpu ?? oldSnapshot.cpu,
            memory: sample.memory ?? oldSnapshot.memory,
            gpuPercent: sample.gpu ?? oldSnapshot.gpuPercent,
            thermalState: oldSnapshot.thermalState,
            temperatures: sample.temperatures ?? oldSnapshot.temperatures,
            fans: sample.fans ?? oldSnapshot.fans
        )
        latestProcesses = sample.processes ?? latestProcesses

        if panelVisible {
            updateHistory(with: sample)
            publishLatestSnapshot()
        } else if menuBarValue(for: latestSnapshot) != menuBarValue(for: state.snapshot) {
            publishLatestSnapshot()
        }
    }

    private func updateHistory(with sample: MetricsSample) {
        var changed = false
        if let cpu = sample.cpu?.value,
           shouldUpdateHistory(.cpu, at: sample.timestamp) {
            cpuHistory.append(MetricSample(timestamp: sample.timestamp, value: cpu.totalPercent))
            changed = true
        }
        if let memory = sample.memory?.value,
           shouldUpdateHistory(.memory, at: sample.timestamp) {
            memoryHistory.append(MetricSample(timestamp: sample.timestamp, value: memory.usagePercent))
            changed = true
        }
        if let gpu = sample.gpu?.value,
           shouldUpdateHistory(.gpu, at: sample.timestamp) {
            gpuHistory.append(MetricSample(timestamp: sample.timestamp, value: gpu))
            changed = true
        }

        if changed {
            latestHistory = MetricHistory(
                cpu: cpuHistory.elements,
                memory: memoryHistory.elements,
                gpu: gpuHistory.elements
            )
        }
    }

    private func shouldUpdateHistory(_ metric: SamplingMetric, at date: Date) -> Bool {
        guard let previous = lastHistoryUpdate[metric],
              date.timeIntervalSince(previous) < 2 else {
            lastHistoryUpdate[metric] = date
            return true
        }
        return false
    }

    private func publishLatestSnapshot() {
        state = MonitorState(
            snapshot: latestSnapshot,
            history: latestHistory,
            processes: latestProcesses
        )
    }

    private func menuBarValue(for snapshot: SystemSnapshot) -> String? {
        switch menuMetric {
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

    private func thermalStateDidChange() {
        latestSnapshot = Self.snapshotWithCurrentThermalState(latestSnapshot)
        if panelVisible {
            publishLatestSnapshot()
        }
    }

    private static func snapshotWithCurrentThermalState(
        _ snapshot: SystemSnapshot
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: snapshot.timestamp,
            cpu: snapshot.cpu,
            memory: snapshot.memory,
            gpuPercent: snapshot.gpuPercent,
            thermalState: currentThermalState,
            temperatures: snapshot.temperatures,
            fans: snapshot.fans
        )
    }

    private static var currentThermalState: SystemThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
