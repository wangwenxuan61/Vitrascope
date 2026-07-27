import Darwin
import Foundation

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
    private typealias ReleaseFunction =
        @convention(c) (OpaquePointer) -> Void

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: UInt32 = 0x000f_0000

    private let create: CreateFunction?
    private let setMatching: SetMatchingFunction?
    private let copyServices: CopyServicesFunction?
    private let copyEvent: CopyEventFunction?
    private let getFloatValue: GetFloatValueFunction?
    private let release: ReleaseFunction?

    init() {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            create = nil
            setMatching = nil
            copyServices = nil
            copyEvent = nil
            getFloatValue = nil
            release = nil
            return
        }

        create = Self.load("IOHIDEventSystemClientCreate", from: handle)
        setMatching = Self.load("IOHIDEventSystemClientSetMatching", from: handle)
        copyServices = Self.load("IOHIDEventSystemClientCopyServices", from: handle)
        copyEvent = Self.load("IOHIDServiceClientCopyEvent", from: handle)
        getFloatValue = Self.load("IOHIDEventGetFloatValue", from: handle)
        release = Self.load("CFRelease", from: handle)
    }

    func readMaximumTemperature() -> Double? {
        guard let create, let setMatching, let copyServices,
              let copyEvent, let getFloatValue, let release,
              let client = create(kCFAllocatorDefault) else {
            return nil
        }
        defer { release(client) }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue() else {
            return nil
        }

        var maximum: Double?
        for index in 0..<CFArrayGetCount(services) {
            let rawService = CFArrayGetValueAtIndex(services, index)
            let service = unsafeBitCast(rawService, to: ServiceClientRef.self)
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
            guard value.isFinite, value > 0, value < 150 else { continue }
            maximum = max(maximum ?? value, value)
        }
        return maximum
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

    mutating func collect() -> SensorAvailability<Double> {
        guard let value = reader.readMaximumTemperature() else {
            return .unavailable("CPU temperature unavailable")
        }
        return .available(value)
    }
}
