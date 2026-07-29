import XCTest
@testable import Vitrascope

final class CollectorTests: XCTestCase {
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
        if case .available(let temperatures) = collector.collect() {
            XCTAssertFalse(temperatures.isEmpty)
            XCTAssertTrue(
                temperatures.allSatisfy {
                    $0.celsius > 0 && $0.celsius < 130
                }
            )
        }
    }

    func testHIDTemperatureClassifierUsesNamedSensorGroups() {
        let readings = HIDTemperatureClassifier.readings(from: [
            HIDTemperatureSample(
                name: "pACC MTR Temp Sensor 1",
                celsius: 60
            ),
            HIDTemperatureSample(
                name: "eACC MTR Temp Sensor 1",
                celsius: 40
            ),
            HIDTemperatureSample(
                name: "GPU MTR Temp Sensor 1",
                celsius: 55
            ),
            HIDTemperatureSample(name: "PMU tdie1", celsius: 70),
            HIDTemperatureSample(name: "PMU2 tdie1", celsius: 50)
        ])

        XCTAssertEqual(
            readings.first(where: { $0.id == "cpu" })?.celsius ?? -1,
            50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            readings.first(where: { $0.id == "gpu" })?.celsius ?? -1,
            55,
            accuracy: 0.001
        )
        XCTAssertEqual(
            readings.first(where: { $0.id == "soc" })?.celsius ?? -1,
            60,
            accuracy: 0.001
        )
    }

    func testHIDTemperatureClassifierRejectsUnrelatedAndInvalidSensors() {
        let readings = HIDTemperatureClassifier.readings(from: [
            HIDTemperatureSample(name: "gas gauge battery", celsius: 30),
            HIDTemperatureSample(name: "NAND CH0 temp", celsius: 55),
            HIDTemperatureSample(name: "PMU tcal", celsius: 52),
            HIDTemperatureSample(name: "PMU tdev1", celsius: 80),
            HIDTemperatureSample(name: "PMU tdie1", celsius: -20),
            HIDTemperatureSample(name: "PMU2 tdie1", celsius: 140)
        ])

        XCTAssertTrue(readings.isEmpty)
    }

    func testProcessCollectorReturnsValidMemoryReadingsOrUnavailable() {
        var collector = ProcessCollector()
        let snapshot = collector.collect()

        if case .available(let processes) = snapshot.topMemory {
            XCTAssertLessThanOrEqual(processes.count, 3)
            XCTAssertTrue(processes.allSatisfy { !$0.name.isEmpty && $0.memoryBytes > 0 })
        }
    }
}
