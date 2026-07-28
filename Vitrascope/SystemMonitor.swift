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

    func requestsActivated(since previous: SamplingProfile) -> SamplingRequest {
        intervals.keys.reduce(into: SamplingRequest()) { request, metric in
            if previous.intervals[metric] == nil {
                request.formUnion(metric.request)
            }
        }
    }
}

private enum SamplingStep {
    case sample(SamplingRequest)
    case sleep(Duration)
    case stop
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
    private var generation: UInt64 = 0

    func sample(
        _ request: SamplingRequest,
        generation requestedGeneration: UInt64,
        resetting baselines: SamplingRequest = []
    ) -> MetricsSample? {
        guard requestedGeneration >= generation else { return nil }
        if requestedGeneration > generation {
            generation = requestedGeneration
        }

        if baselines.contains(.cpu) {
            cpuCollector.reset()
        }
        if baselines.contains(.processes) {
            processCollector.reset()
        }

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
    private var lastHistoryUpdate: [SamplingMetric: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    private var lastSample: [SamplingMetric: ContinuousClock.Instant] = [:]
    private var samplingTask: Task<Void, Never>?
    private var samplingGeneration: UInt64 = 0
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
        let previousProfile = currentProfile
        panelVisible = isVisible
        let profile = currentProfile
        let activatedRequests = profile.requestsActivated(since: previousProfile)

        if isVisible {
            markCollecting(activatedRequests)
            resetHistory()
            publishLatestSnapshot()
        }

        restartSampling(
            force: isVisible ? activatedRequests : [],
            resetting: activatedRequests
        )
    }

    func setMenuMetric(_ metric: MetricKind) {
        guard menuMetric != metric else { return }
        let previousProfile = currentProfile
        menuMetric = metric

        if !panelVisible {
            let profile = currentProfile
            let activatedRequests = profile.requestsActivated(since: previousProfile)
            markCollecting(activatedRequests)
            publishLatestSnapshot()
            restartSampling(
                force: requestForCurrentProfile(),
                resetting: activatedRequests
            )
        }
    }

    private func restartSampling(
        force: SamplingRequest,
        resetting activatedRequests: SamplingRequest = []
    ) {
        samplingTask?.cancel()
        samplingGeneration &+= 1
        let generation = samplingGeneration
        for metric in SamplingMetric.allCases where activatedRequests.contains(metric.request) {
            lastSample[metric] = nil
        }

        let profile = currentProfile
        guard !profile.intervals.isEmpty else {
            samplingTask = nil
            return
        }

        let sampler = sampler
        samplingTask = Task { [weak self, sampler] in
            var forcedRequest = force
            var pendingBaselineReset = activatedRequests
            while !Task.isCancelled {
                guard let step = self?.samplingStep(forcedRequest: forcedRequest) else {
                    return
                }
                forcedRequest = []

                switch step {
                case .sample(let request):
                    let sample = await sampler.sample(
                        request,
                        generation: generation,
                        resetting: pendingBaselineReset
                    )
                    pendingBaselineReset = []
                    guard !Task.isCancelled, let sample, let self else { return }
                    recordSampleTimes(for: request)
                    update(with: sample)
                case .sleep(let delay):
                    do {
                        try await Task.sleep(
                            for: delay,
                            tolerance: max(delay / 10, Duration.milliseconds(50)),
                            clock: .continuous
                        )
                    } catch {
                        return
                    }
                case .stop:
                    return
                }
            }
        }
    }

    private func samplingStep(forcedRequest: SamplingRequest) -> SamplingStep {
        let profile = currentProfile
        guard !profile.intervals.isEmpty else { return .stop }

        let now = clock.now
        var request = forcedRequest
        for (metric, interval) in profile.intervals {
            guard let lastSample = lastSample[metric] else {
                request.formUnion(metric.request)
                continue
            }
            if lastSample.duration(to: now) >= .seconds(interval) {
                request.formUnion(metric.request)
            }
        }

        if !request.isEmpty {
            return .sample(request)
        }

        let delay = profile.intervals.compactMap { metric, interval -> Duration? in
            guard let sampledAt = lastSample[metric] else { return .zero }
            let elapsed = sampledAt.duration(to: now)
            return max(.seconds(interval) - elapsed, .zero)
        }.min() ?? .seconds(1)
        return .sleep(delay)
    }

    private var currentProfile: SamplingProfile {
        SamplingProfile.profile(panelVisible: panelVisible, menuMetric: menuMetric)
    }

    private func requestForCurrentProfile() -> SamplingRequest {
        currentProfile.intervals.keys.reduce(into: SamplingRequest()) { request, metric in
            request.formUnion(metric.request)
        }
    }

    private func recordSampleTimes(for request: SamplingRequest) {
        let instant = clock.now
        for metric in SamplingMetric.allCases where request.contains(metric.request) {
            lastSample[metric] = instant
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
           shouldUpdateHistory(.cpu) {
            cpuHistory.append(MetricSample(timestamp: sample.timestamp, value: cpu.totalPercent))
            changed = true
        }
        if let memory = sample.memory?.value,
           shouldUpdateHistory(.memory) {
            memoryHistory.append(MetricSample(timestamp: sample.timestamp, value: memory.usagePercent))
            changed = true
        }
        if let gpu = sample.gpu?.value,
           shouldUpdateHistory(.gpu) {
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

    private func shouldUpdateHistory(_ metric: SamplingMetric) -> Bool {
        let now = clock.now
        guard let previous = lastHistoryUpdate[metric],
              previous.duration(to: now) < .seconds(2) else {
            lastHistoryUpdate[metric] = now
            return true
        }
        return false
    }

    private func resetHistory() {
        cpuHistory = FixedRingBuffer(capacity: 30)
        memoryHistory = FixedRingBuffer(capacity: 30)
        gpuHistory = FixedRingBuffer(capacity: 30)
        latestHistory = .empty
        lastHistoryUpdate.removeAll(keepingCapacity: true)
    }

    private func markCollecting(_ requests: SamplingRequest) {
        let oldSnapshot = latestSnapshot
        latestSnapshot = SystemSnapshot(
            timestamp: .now,
            cpu: requests.contains(.cpu) ? .unavailable("Collecting") : oldSnapshot.cpu,
            memory: requests.contains(.memory) ? .unavailable("Collecting") : oldSnapshot.memory,
            gpuPercent: requests.contains(.gpu) ? .unavailable("Collecting") : oldSnapshot.gpuPercent,
            thermalState: oldSnapshot.thermalState,
            temperatures: requests.contains(.thermal)
                ? .unavailable("Collecting")
                : oldSnapshot.temperatures,
            fans: requests.contains(.thermal) ? .unavailable("Collecting") : oldSnapshot.fans
        )
        if requests.contains(.processes) {
            latestProcesses = .empty
        }
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
