import Darwin
import Foundation

struct ProcessResourceSample: Equatable, Sendable {
    let pid: Int32
    let name: String
    let cpuTimeTicks: UInt64
    let memoryBytes: UInt64
    let startTime: UInt64
}

enum ProcessMetricsCalculator {
    static func snapshot(
        current: [ProcessResourceSample],
        previous: [ProcessResourceSample],
        elapsedNanoseconds: UInt64,
        timebaseNumerator: UInt32 = 1,
        timebaseDenominator: UInt32 = 1,
        limit: Int = 3
    ) -> ProcessMetricsSnapshot {
        let previousByProcess = Dictionary(
            uniqueKeysWithValues: previous.map {
                (ProcessIdentity(pid: $0.pid, startTime: $0.startTime), $0)
            }
        )

        let readings = current.map { sample in
            let identity = ProcessIdentity(pid: sample.pid, startTime: sample.startTime)
            let previousCPUTime = previousByProcess[identity]?.cpuTimeTicks
            let cpuPercent: Double
            if let previousCPUTime,
               sample.cpuTimeTicks >= previousCPUTime,
               elapsedNanoseconds > 0,
               timebaseDenominator > 0 {
                let deltaTicks = sample.cpuTimeTicks - previousCPUTime
                let deltaNanoseconds = Double(deltaTicks)
                    * Double(timebaseNumerator)
                    / Double(timebaseDenominator)
                cpuPercent = deltaNanoseconds
                    / Double(elapsedNanoseconds) * 100
            } else {
                cpuPercent = 0
            }

            return ProcessResourceReading(
                pid: sample.pid,
                name: sample.name,
                cpuPercent: cpuPercent.isFinite ? max(cpuPercent, 0) : 0,
                memoryBytes: sample.memoryBytes
            )
        }

        let count = max(limit, 0)
        let topCPU = readings
            .filter { $0.cpuPercent > 0 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(count)
        let topMemory = readings
            .filter { $0.memoryBytes > 0 }
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(count)

        return ProcessMetricsSnapshot(
            topCPU: topCPU.isEmpty
                ? .unavailable("No active processes")
                : .available(Array(topCPU)),
            topMemory: topMemory.isEmpty
                ? .unavailable("No process data")
                : .available(Array(topMemory))
        )
    }

    private struct ProcessIdentity: Hashable {
        let pid: Int32
        let startTime: UInt64
    }
}

struct ProcessCollector: MetricCollector {
    private var previousSamples: [ProcessResourceSample] = []
    private var previousTimestamp: UInt64?
    private let timebase: mach_timebase_info_data_t

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
    }

    mutating func collect() -> ProcessMetricsSnapshot {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let samples = readSamples()
        defer {
            previousSamples = samples
            previousTimestamp = timestamp
        }

        guard !samples.isEmpty else {
            return ProcessMetricsSnapshot(
                topCPU: .unavailable("Process data unavailable"),
                topMemory: .unavailable("Process data unavailable")
            )
        }

        let memorySnapshot = ProcessMetricsCalculator.snapshot(
            current: samples,
            previous: [],
            elapsedNanoseconds: 0
        )
        guard let previousTimestamp, timestamp > previousTimestamp else {
            return ProcessMetricsSnapshot(
                topCPU: .unavailable("Calculating"),
                topMemory: memorySnapshot.topMemory
            )
        }

        return ProcessMetricsCalculator.snapshot(
            current: samples,
            previous: previousSamples,
            elapsedNanoseconds: timestamp - previousTimestamp,
            timebaseNumerator: timebase.numer,
            timebaseDenominator: timebase.denom
        )
    }

    private func readSamples() -> [ProcessResourceSample] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 32)
        let returnedCount = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return [] }

        return pids.prefix(Int(returnedCount)).compactMap(readSample)
    }

    private func readSample(pid: pid_t) -> ProcessResourceSample? {
        guard pid > 0 else { return nil }

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }

        let cpuTime = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard !cpuTime.overflow else { return nil }

        return ProcessResourceSample(
            pid: pid,
            name: processName(pid: pid),
            cpuTimeTicks: cpuTime.partialValue,
            memoryBytes: usage.ri_phys_footprint,
            startTime: usage.ri_proc_start_abstime
        )
    }

    private func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "Process \(pid)" }
        return buffer.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(Int(length)), as: UTF8.self)
        }
    }
}
