import Darwin
import Foundation

struct HIDTemperatureSample: Equatable, Sendable {
    let name: String
    let celsius: Double
}

enum HIDTemperatureClassifier {
    static func readings(
        from samples: [HIDTemperatureSample]
    ) -> [TemperatureReading] {
        var cpu: [Double] = []
        var gpu: [Double] = []
        var soc: [Double] = []

        for sample in samples where isValid(sample.celsius) {
            let name = sample.name.lowercased()
            if isCPU(name) {
                cpu.append(sample.celsius)
            } else if name.hasPrefix("gpu mtr temp sensor") {
                gpu.append(sample.celsius)
            } else if name.hasPrefix("soc mtr temp sensor")
                        || (name.hasPrefix("pmu") && name.contains(" tdie")) {
                soc.append(sample.celsius)
            }
        }

        return [
            reading(id: "cpu", label: "CPU Average", values: cpu),
            reading(id: "gpu", label: "GPU Average", values: gpu),
            reading(id: "soc", label: "SoC Estimate", values: soc)
        ].compactMap { $0 }
    }

    private static func isCPU(_ name: String) -> Bool {
        ["pacc", "eacc", "sacc", "macc"].contains { prefix in
            name.hasPrefix("\(prefix) mtr temp sensor")
        }
    }

    private static func isValid(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value < 130
    }

    private static func reading(
        id: String,
        label: String,
        values: [Double]
    ) -> TemperatureReading? {
        guard !values.isEmpty else { return nil }
        return TemperatureReading(
            id: id,
            label: label,
            celsius: values.reduce(0, +) / Double(values.count)
        )
    }
}

private final class HIDTemperatureReader {
    private typealias EventSystemClientRef = OpaquePointer
    private typealias ServiceClientRef = OpaquePointer
    private typealias EventRef = OpaquePointer

    private typealias CreateFunction =
        @convention(c) (CFAllocator?) -> EventSystemClientRef?
    private typealias SetMatchingFunction =
        @convention(c) (EventSystemClientRef, CFDictionary?) -> Void
    private typealias CopyServicesFunction =
        @convention(c) (EventSystemClientRef) -> Unmanaged<CFArray>?
    private typealias CopyEventFunction =
        @convention(c) (ServiceClientRef, Int64, Int32, Int64) -> EventRef?
    private typealias GetFloatValueFunction =
        @convention(c) (EventRef, UInt32) -> Double
    private typealias CopyPropertyFunction =
        @convention(c) (ServiceClientRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ReleaseFunction =
        @convention(c) (OpaquePointer) -> Void

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: UInt32 = 0x000f_0000

    private let create: CreateFunction?
    private let setMatching: SetMatchingFunction?
    private let copyServices: CopyServicesFunction?
    private let copyEvent: CopyEventFunction?
    private let getFloatValue: GetFloatValueFunction?
    private let copyProperty: CopyPropertyFunction?
    private let release: ReleaseFunction?

    init() {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            create = nil
            setMatching = nil
            copyServices = nil
            copyEvent = nil
            getFloatValue = nil
            copyProperty = nil
            release = nil
            return
        }

        create = Self.load("IOHIDEventSystemClientCreate", from: handle)
        setMatching = Self.load("IOHIDEventSystemClientSetMatching", from: handle)
        copyServices = Self.load("IOHIDEventSystemClientCopyServices", from: handle)
        copyEvent = Self.load("IOHIDServiceClientCopyEvent", from: handle)
        getFloatValue = Self.load("IOHIDEventGetFloatValue", from: handle)
        copyProperty = Self.load("IOHIDServiceClientCopyProperty", from: handle)
        release = Self.load("CFRelease", from: handle)
    }

    func readTemperatures() -> [HIDTemperatureSample] {
        guard let create, let setMatching, let copyServices,
              let copyEvent, let getFloatValue, let copyProperty, let release,
              let client = create(kCFAllocatorDefault) else {
            return []
        }
        defer { release(client) }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue() else {
            return []
        }

        var samples: [HIDTemperatureSample] = []
        for index in 0..<CFArrayGetCount(services) {
            let rawService = CFArrayGetValueAtIndex(services, index)
            let service = unsafeBitCast(rawService, to: ServiceClientRef.self)
            guard let product = copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String else {
                continue
            }
            guard let event = copyEvent(
                service,
                Self.temperatureEventType,
                0,
                0
            ) else {
                continue
            }

            let value = getFloatValue(event, Self.temperatureLevelField)
            release(event)
            samples.append(HIDTemperatureSample(name: product, celsius: value))
        }
        return samples
    }

    private static func load<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> Function? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }
}

struct HIDTemperatureCollector: MetricCollector {
    private let reader = HIDTemperatureReader()

    mutating func collect() -> SensorAvailability<[TemperatureReading]> {
        let readings = HIDTemperatureClassifier.readings(
            from: reader.readTemperatures()
        )
        guard !readings.isEmpty else {
            return .unavailable("Temperature sensors unavailable")
        }
        return .available(readings)
    }
}
