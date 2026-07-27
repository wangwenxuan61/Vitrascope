import Foundation

enum MetricFormatting {
    private static let byteFormatter = LockedByteCountFormatter()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func processPercent(_ value: Double) -> String {
        if value > 0, value < 0.1 {
            return "<0.1%"
        }
        if value < 10 {
            return String(
                format: "%.1f%%",
                locale: Locale(identifier: "en_US_POSIX"),
                value
            )
        }
        return percent(value)
    }

    static func temperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }

    static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded())) RPM"
    }
}

private final class LockedByteCountFormatter: @unchecked Sendable {
    private let formatter: ByteCountFormatter
    private let lock = NSLock()

    init() {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        self.formatter = formatter
    }

    func string(fromByteCount value: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: value)
    }
}

struct FixedRingBuffer<Element> {
    private var storage: [Element?]
    private var nextIndex = 0
    private var count = 0
    let capacity: Int

    var elements: [Element] {
        let start = count == capacity ? nextIndex : 0
        return (0..<count).compactMap { offset in
            storage[(start + offset) % capacity]
        }
    }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[nextIndex] = element
        nextIndex = (nextIndex + 1) % capacity
        count = min(count + 1, capacity)
    }
}
