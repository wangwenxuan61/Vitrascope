import Darwin
import Foundation

enum MemoryUsageCalculator {
    static func reading(
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64,
        swapUsedBytes: UInt64
    ) -> MemoryReading {
        let usedPages = activePages + wiredPages + compressedPages
        let (rawUsedBytes, overflow) = usedPages.multipliedReportingOverflow(by: pageSize)
        let usedBytes = overflow ? totalBytes : min(rawUsedBytes, totalBytes)
        return MemoryReading(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            swapUsedBytes: swapUsedBytes
        )
    }
}

struct MemoryCollector: MetricCollector {
    mutating func collect() -> SensorAvailability<MemoryReading> {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unavailable("Memory data unavailable")
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return .unavailable("Memory data unavailable")
        }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let reading = MemoryUsageCalculator.reading(
            activePages: UInt64(statistics.active_count),
            wiredPages: UInt64(statistics.wire_count),
            compressedPages: UInt64(statistics.compressor_page_count),
            pageSize: UInt64(pageSize),
            totalBytes: totalBytes,
            swapUsedBytes: readSwapUsedBytes()
        )
        return .available(reading)
    }

    private func readSwapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? usage.xsu_used : 0
    }
}
