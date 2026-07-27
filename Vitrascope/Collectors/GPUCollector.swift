import Foundation
import IOKit

private final class GPUServiceCache {
    private(set) var services: [io_service_t] = []

    deinit {
        invalidate()
    }

    func replace(with services: [io_service_t]) {
        invalidate()
        self.services = services
    }

    func invalidate() {
        services.forEach { service in
            IOObjectRelease(service)
        }
        services.removeAll(keepingCapacity: true)
    }

    var isValid: Bool {
        guard !services.isEmpty else { return false }
        return services.allSatisfy { service in
            var registryID: UInt64 = 0
            return IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS
        }
    }
}

struct GPUCollector: MetricCollector {
    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Core Utilization",
        "GPU Busy",
        "GPU Activity(%)"
    ]
    private let serviceCache = GPUServiceCache()

    mutating func collect() -> SensorAvailability<Double> {
        if !serviceCache.isValid {
            guard refreshServices() else {
                return .unavailable("GPU data unavailable")
            }
        }

        let values = serviceCache.services.compactMap(readUtilization)
        guard let value = values.max(), value.isFinite else {
            return .unavailable("Not exposed by this Mac")
        }
        return .available(min(max(value, 0), 100))
    }

    private func refreshServices() -> Bool {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            services.append(service)
            service = IOIteratorNext(iterator)
        }
        serviceCache.replace(with: services)
        return !services.isEmpty
    }

    private func readUtilization(from service: io_service_t) -> Double? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        for key in Self.utilizationKeys {
            if let number = property[key] as? NSNumber {
                return number.doubleValue
            }
        }
        return nil
    }
}
