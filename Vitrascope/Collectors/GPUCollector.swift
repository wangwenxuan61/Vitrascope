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
    private static let emptyReadRefreshInterval: Duration = .seconds(30)

    private let serviceCache = GPUServiceCache()
    private let clock = ContinuousClock()
    private var lastServiceRefresh: ContinuousClock.Instant?

    mutating func collect() -> SensorAvailability<Double> {
        var refreshedServices = false
        if !serviceCache.isValid {
            refreshedServices = refreshServicesIfAllowed(
                force: !serviceCache.services.isEmpty
            )
            guard serviceCache.isValid else {
                return .unavailable("GPU data unavailable")
            }
        }

        var values = serviceCache.services.compactMap(readUtilization)
        if values.isEmpty,
           !refreshedServices,
           refreshServicesIfAllowed(force: false) {
            values = serviceCache.services.compactMap(readUtilization)
        }

        guard let value = values.max(), value.isFinite else {
            return .unavailable("Not exposed by this Mac")
        }
        return .available(min(max(value, 0), 100))
    }

    private mutating func refreshServicesIfAllowed(force: Bool) -> Bool {
        let now = clock.now
        if !force,
           let lastServiceRefresh,
           lastServiceRefresh.duration(to: now) < Self.emptyReadRefreshInterval {
            return false
        }

        lastServiceRefresh = now
        _ = refreshServices()
        return true
    }

    private func refreshServices() -> Bool {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            serviceCache.invalidate()
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
