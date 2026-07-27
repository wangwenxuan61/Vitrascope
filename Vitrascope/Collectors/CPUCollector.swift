@preconcurrency import Darwin
import Foundation

struct CPUTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user + system + idle + nice }
}

enum CPUUsageCalculator {
    static func reading(previous: CPUTicks, current: CPUTicks) -> CPUReading? {
        guard current.total >= previous.total else { return nil }

        let user = current.user - previous.user
        let system = current.system - previous.system
        let idle = current.idle - previous.idle
        let nice = current.nice - previous.nice
        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let denominator = Double(total)
        let userPercent = Double(user + nice) / denominator * 100
        let systemPercent = Double(system) / denominator * 100
        return CPUReading(
            totalPercent: min(max(userPercent + systemPercent, 0), 100),
            userPercent: min(max(userPercent, 0), 100),
            systemPercent: min(max(systemPercent, 0), 100)
        )
    }
}

struct CPUCollector: MetricCollector {
    private var previousTicks: CPUTicks?

    mutating func collect() -> SensorAvailability<CPUReading> {
        guard let currentTicks = readTicks() else {
            return .unavailable("CPU data unavailable")
        }

        defer { previousTicks = currentTicks }
        guard let previousTicks,
              let reading = CPUUsageCalculator.reading(previous: previousTicks, current: currentTicks) else {
            return .unavailable("Collecting")
        }
        return .available(reading)
    }

    private func readTicks() -> CPUTicks? {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: cpuInfo)),
                vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let statesPerCPU = Int(CPU_STATE_MAX)
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * statesPerCPU
            user += UInt64(max(cpuInfo[offset + Int(CPU_STATE_USER)], 0))
            system += UInt64(max(cpuInfo[offset + Int(CPU_STATE_SYSTEM)], 0))
            idle += UInt64(max(cpuInfo[offset + Int(CPU_STATE_IDLE)], 0))
            nice += UInt64(max(cpuInfo[offset + Int(CPU_STATE_NICE)], 0))
        }

        return CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }
}
