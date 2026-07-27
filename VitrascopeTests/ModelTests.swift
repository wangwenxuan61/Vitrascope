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

    func testStableFormatting() {
        XCTAssertEqual(MetricFormatting.percent(41.6), "42%")
        XCTAssertEqual(MetricFormatting.temperature(53.4), "53°C")
        XCTAssertEqual(MetricFormatting.rpm(1_999.6), "2000 RPM")
    }
}
