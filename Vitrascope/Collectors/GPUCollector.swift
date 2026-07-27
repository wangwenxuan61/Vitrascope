import Foundation
import IOKit

struct GPUCollector: MetricCollector {
    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Core Utilization",
        "GPU Busy",
        "GPU Activity(%)"
    ]

    mutating func collect() -> SensorAvailability<Double> {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return .unavailable("GPU data unavailable")
        }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            for key in Self.utilizationKeys {
                if let number = property[key] as? NSNumber {
                    values.append(number.doubleValue)
                    break
                }
            }
        }

        guard let value = values.max(), value.isFinite else {
            return .unavailable("Not exposed by this Mac")
        }
        return .available(min(max(value, 0), 100))
    }
}
