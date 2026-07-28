import XCTest
@testable import Vitrascope

final class CollectorTests: XCTestCase {
    func testCPUCollectorResetRequiresANewBaseline() {
        var collector = CPUCollector()
        _ = collector.collect()
        _ = collector.collect()

        collector.reset()

        XCTAssertEqual(collector.collect(), .unavailable("Collecting"))
    }

    func testMemoryCollectorReturnsValidReadingOrUnavailable() {
        var collector = MemoryCollector()
        switch collector.collect() {
        case .available(let reading):
            XCTAssertGreaterThan(reading.totalBytes, 0)
            XCTAssertGreaterThanOrEqual(reading.usagePercent, 0)
            XCTAssertLessThanOrEqual(reading.usagePercent, 100)
        case .unavailable:
            break
        }
    }

    func testGPUCollectorStaysWithinPercentRangeWhenAvailable() {
        var collector = GPUCollector()
        if case .available(let percent) = collector.collect() {
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
    }

    func testSMCCollectorRejectsInvalidSensorValues() {
        var collector = SMCCollector()
        let readings = collector.collect()

        if case .available(let temperatures) = readings.temperatures {
            XCTAssertTrue(temperatures.allSatisfy { $0.celsius > 0 && $0.celsius < 130 })
        }
        if case .available(let fans) = readings.fans {
            XCTAssertTrue(fans.allSatisfy { $0.rpm >= 0 })
        }
    }

    func testHIDTemperatureCollectorReturnsValidReadingOrUnavailable() {
        var collector = HIDTemperatureCollector()
        if case .available(let temperature) = collector.collect() {
            XCTAssertGreaterThan(temperature, 0)
            XCTAssertLessThan(temperature, 150)
        }
    }

    func testProcessCollectorReturnsValidMemoryReadingsOrUnavailable() {
        var collector = ProcessCollector()
        let snapshot = collector.collect()

        if case .available(let processes) = snapshot.topMemory {
            XCTAssertLessThanOrEqual(processes.count, 3)
            XCTAssertTrue(processes.allSatisfy { !$0.name.isEmpty && $0.memoryBytes > 0 })
        }
    }

    func testProcessCollectorResetRequiresANewCPUBaseline() {
        var collector = ProcessCollector()
        _ = collector.collect()
        _ = collector.collect()

        collector.reset()

        XCTAssertEqual(collector.collect().topCPU, .unavailable("Calculating"))
    }
}
