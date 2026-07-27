import Foundation

enum MetricFormatting {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: value))
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

struct FixedRingBuffer<Element> {
    private(set) var elements: [Element] = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }
}
