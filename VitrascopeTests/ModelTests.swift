import XCTest
@testable import Vitrascope

final class ModelTests: XCTestCase {
    func testCPUUsageUsesTickDeltas() {
        let previous = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUTicks(user: 200, system: 100, idle: 1_700, nice: 0)

        let reading = CPUUsageCalculator.reading(previous: previous, current: current)

        XCTAssertEqual(reading?.totalPercent ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(reading?.userPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(reading?.systemPercent ?? -1, 5, accuracy: 0.001)
    }

    func testCPUUsageRejectsZeroDelta() {
        let ticks = CPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        XCTAssertNil(CPUUsageCalculator.reading(previous: ticks, current: ticks))
    }

    func testMemoryCalculationClampsToPhysicalTotal() {
        let reading = MemoryUsageCalculator.reading(
            activePages: 100,
            wiredPages: 100,
            compressedPages: 100,
            pageSize: 4_096,
            totalBytes: 1_000_000,
            swapUsedBytes: 42
        )

        XCTAssertEqual(reading.usedBytes, 1_000_000)
        XCTAssertEqual(reading.totalBytes, 1_000_000)
        XCTAssertEqual(reading.swapUsedBytes, 42)
        XCTAssertEqual(reading.usagePercent, 100, accuracy: 0.001)
    }

    func testRingBufferKeepsNewestValues() {
        var buffer = FixedRingBuffer<Int>(capacity: 3)
        (1...5).forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
    }

    func testClosedPanelSamplesOnlySelectedMetric() {
        XCTAssertEqual(
            SamplingProfile.profile(panelVisible: false, menuMetric: .cpu).intervals,
            [.cpu: 1]
        )
        XCTAssertEqual(
            SamplingProfile.profile(panelVisible: false, menuMetric: .memory).intervals,
            [.memory: 2]
        )
        XCTAssertEqual(
            SamplingProfile.profile(panelVisible: false, menuMetric: .gpu).intervals,
            [.gpu: 2]
        )
        XCTAssertEqual(
            SamplingProfile.profile(panelVisible: false, menuMetric: .temperature).intervals,
            [.thermal: 5]
        )
        XCTAssertTrue(
            SamplingProfile.profile(panelVisible: false, menuMetric: .iconOnly).intervals.isEmpty
        )
    }

    func testOpenPanelUsesTieredSamplingIntervals() {
        XCTAssertEqual(
            SamplingProfile.profile(panelVisible: true, menuMetric: .iconOnly).intervals,
            [.cpu: 1, .memory: 2, .gpu: 2, .thermal: 5, .processes: 2]
        )
    }

    func testMetricKindPersistsByRawValue() {
        for metric in MetricKind.allCases {
            XCTAssertEqual(MetricKind(rawValue: metric.rawValue), metric)
        }
    }

    func testUnavailableSensorHasNoValue() {
        let reading: SensorAvailability<Double> = .unavailable("Not exposed")
        XCTAssertNil(reading.value)
    }

    func testSnapshotExposesCPUTemperature() {
        let snapshot = SystemSnapshot(
            timestamp: .now,
            cpu: .unavailable("Collecting"),
            memory: .unavailable("Collecting"),
            gpuPercent: .unavailable("Collecting"),
            thermalState: .nominal,
            temperatures: .available([
                TemperatureReading(id: "gpu", label: "GPU", celsius: 48),
                TemperatureReading(id: "cpu", label: "CPU", celsius: 62.5)
            ]),
            fans: .unavailable("No fan data")
        )

        XCTAssertEqual(snapshot.cpuTemperature.value ?? -1, 62.5, accuracy: 0.001)
    }

    func testProcessMetricsSortCPUAndMemoryIndependently() {
        let previous = [
            ProcessResourceSample(
                pid: 1,
                name: "Memory App",
                cpuTimeTicks: 100,
                memoryBytes: 900,
                startTime: 10
            ),
            ProcessResourceSample(
                pid: 2,
                name: "CPU App",
                cpuTimeTicks: 100,
                memoryBytes: 100,
                startTime: 20
            )
        ]
        let current = [
            ProcessResourceSample(
                pid: 1,
                name: "Memory App",
                cpuTimeTicks: 200,
                memoryBytes: 900,
                startTime: 10
            ),
            ProcessResourceSample(
                pid: 2,
                name: "CPU App",
                cpuTimeTicks: 600,
                memoryBytes: 100,
                startTime: 20
            )
        ]

        let snapshot = ProcessMetricsCalculator.snapshot(
            current: current,
            previous: previous,
            elapsedNanoseconds: 1_000,
            limit: 2
        )

        XCTAssertEqual(snapshot.topCPU.value?.map(\.name), ["CPU App", "Memory App"])
        XCTAssertEqual(snapshot.topMemory.value?.map(\.name), ["Memory App", "CPU App"])
        XCTAssertEqual(snapshot.topCPU.value?.first?.cpuPercent ?? -1, 50, accuracy: 0.001)
    }

    func testProcessMetricsApplyMachTimebase() {
        let previous = [
            ProcessResourceSample(
                pid: 1,
                name: "Busy App",
                cpuTimeTicks: 100,
                memoryBytes: 100,
                startTime: 10
            )
        ]
        let current = [
            ProcessResourceSample(
                pid: 1,
                name: "Busy App",
                cpuTimeTicks: 124,
                memoryBytes: 100,
                startTime: 10
            )
        ]

        let snapshot = ProcessMetricsCalculator.snapshot(
            current: current,
            previous: previous,
            elapsedNanoseconds: 1_000,
            timebaseNumerator: 125,
            timebaseDenominator: 3
        )

        XCTAssertEqual(snapshot.topCPU.value?.first?.cpuPercent ?? -1, 100, accuracy: 0.001)
    }

    func testProcessMetricsIgnoreReusedPIDForCPU() {
        let previous = [
            ProcessResourceSample(
                pid: 42,
                name: "Old Process",
                cpuTimeTicks: 900,
                memoryBytes: 100,
                startTime: 1
            )
        ]
        let current = [
            ProcessResourceSample(
                pid: 42,
                name: "New Process",
                cpuTimeTicks: 10,
                memoryBytes: 100,
                startTime: 2
            )
        ]

        let snapshot = ProcessMetricsCalculator.snapshot(
            current: current,
            previous: previous,
            elapsedNanoseconds: 1_000
        )

        XCTAssertNil(snapshot.topCPU.value)
    }

    func testStableFormatting() {
        XCTAssertEqual(MetricFormatting.percent(41.6), "42%")
        XCTAssertEqual(MetricFormatting.processPercent(4.24), "4.2%")
        XCTAssertEqual(MetricFormatting.processPercent(0.04), "<0.1%")
        XCTAssertEqual(MetricFormatting.processPercent(14.6), "15%")
        XCTAssertEqual(MetricFormatting.temperature(53.4), "53°C")
        XCTAssertEqual(MetricFormatting.rpm(1_999.6), "2000 RPM")
    }

    func testMenuBarValuesUseFixedColumns() {
        XCTAssertEqual(MenuBarLabel.fixedColumns(for: "9%"), ["", "", "9", "%", ""])
        XCTAssertEqual(MenuBarLabel.fixedColumns(for: "60%"), ["", "6", "0", "%", ""])
        XCTAssertEqual(MenuBarLabel.fixedColumns(for: "100%"), ["1", "0", "0", "%", ""])
        XCTAssertEqual(MenuBarLabel.fixedColumns(for: "63°C"), ["", "6", "3", "°", "C"])
        XCTAssertEqual(MenuBarLabel.fixedColumns(for: nil), ["", "—", "", "", ""])
    }

    func testMenuBarValuesRenderAsSingleFixedWidthText() {
        XCTAssertEqual(MenuBarLabel.fixedText(for: "9%"), "  9% ")
        XCTAssertEqual(MenuBarLabel.fixedText(for: "60%"), " 60% ")
        XCTAssertEqual(MenuBarLabel.fixedText(for: "100%"), "100% ")
        XCTAssertEqual(MenuBarLabel.fixedText(for: "63°C"), " 63°C")
        XCTAssertEqual(MenuBarLabel.fixedText(for: nil), " —   ")
        XCTAssertEqual(MenuBarLabel.fixedText(for: "9%").count, 5)
        XCTAssertEqual(MenuBarLabel.fixedText(for: "100%").count, 5)
        XCTAssertEqual(MenuBarLabel.fixedText(for: "63°C").count, 5)
    }

    func testTemperatureColorLevels() {
        XCTAssertEqual(TemperatureLevel(celsius: 69.9), .normal)
        XCTAssertEqual(TemperatureLevel(celsius: 70), .elevated)
        XCTAssertEqual(TemperatureLevel(celsius: 84.9), .elevated)
        XCTAssertEqual(TemperatureLevel(celsius: 85), .hot)
    }
}
