@preconcurrency import Darwin
import Foundation
import IOKit

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    let dataType: String
    let bytes: [UInt8]

    var numericValue: Double? {
        guard bytes.count >= 2 else {
            return bytes.first.map(Double.init)
        }

        switch dataType {
        case "sp78":
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256
        case "fpe2":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt " where bytes.count >= 4:
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            let value = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            return Double(value)
        default:
            return nil
        }
    }
}

private final class SMCConnection {
    private static let kernelIndex: UInt32 = 2
    private static let readKeyInfoCommand: UInt8 = 9
    private static let readBytesCommand: UInt8 = 5
    private static let getKeyFromIndexCommand: UInt8 = 8

    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private(set) var isUsable = true

    init?() {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func read(_ key: String) -> SMCValue? {
        guard isUsable, let keyCode = Self.fourCharacterCode(key) else { return nil }

        let cachedKeyInfo = keyInfoCache[keyCode]
        let keyInfo: SMCKeyInfoData
        if let cached = cachedKeyInfo {
            keyInfo = cached
        } else {
            var input = SMCParamStruct()
            var output = SMCParamStruct()
            var outputSize = MemoryLayout<SMCParamStruct>.stride
            input.key = keyCode
            input.data8 = Self.readKeyInfoCommand

            let result = withUnsafePointer(to: &input) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    IOConnectCallStructMethod(
                        connection,
                        Self.kernelIndex,
                        inputPointer,
                        MemoryLayout<SMCParamStruct>.stride,
                        outputPointer,
                        &outputSize
                    )
                }
            }
            guard result == KERN_SUCCESS else {
                return nil
            }
            keyInfo = output.keyInfo
            keyInfoCache[keyCode] = keyInfo
        }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = Self.readBytesCommand

        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelIndex,
                    inputPointer,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            if cachedKeyInfo != nil, keyInfo.dataSize > 0 {
                isUsable = false
            }
            return nil
        }

        let byteCount = min(Int(keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(byteCount)) }
        return SMCValue(dataType: Self.string(from: keyInfo.dataType), bytes: bytes)
    }

    func temperatureKeys() -> [String] {
        guard let countValue = read("#KEY")?.numericValue else { return [] }
        let count = min(max(Int(countValue), 0), 8_192)
        return (0..<count).compactMap { index in
            guard let key = key(at: UInt32(index)), key.hasPrefix("T") else { return nil }
            return key
        }
    }

    private func key(at index: UInt32) -> String? {
        guard isUsable else { return nil }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        input.data8 = Self.getKeyFromIndexCommand
        input.data32 = index

        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelIndex,
                    inputPointer,
                    MemoryLayout<SMCParamStruct>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS, output.key != 0 else { return nil }
        return Self.string(from: output.key)
    }

    private static func fourCharacterCode(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

struct SMCReadings: Equatable, Sendable {
    let temperatures: SensorAvailability<[TemperatureReading]>
    let fans: SensorAvailability<[FanReading]>
}

struct SMCCollector: MetricCollector {
    private static let fallbackTemperatureGroups: [(label: String, keys: [String])] = [
        (
            "CPU",
            [
                "TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C",
                "TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
                "TC30", "TC31", "TC32", "TC33", "TC40", "TC41", "TC42", "TC43",
                "TC50", "TC51", "TC52", "TC53",
                "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
                "Tp0V", "Tp0X", "Tp0Y", "Tp0b", "Tp0e", "Tp0f", "Tp0j",
                "Tp1h", "Tp1t", "Tp1p", "Tp1l",
                "Te05", "Te09", "Te0H", "Te0L", "Te0P", "Te0S", "Te0T",
                "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"
            ]
        ),
        (
            "GPU",
            [
                "TG0P", "TG0D", "Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0G", "Tg0H",
                "Tg0K", "Tg0L", "Tg0P", "Tg0S", "Tg0T", "Tg0d", "Tg0e", "Tg0f",
                "Tg0j", "Tg0k", "Tg1U", "Tg1k",
                "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"
            ]
        )
    ]
    private var connection: SMCConnection?
    private var candidateTemperatureGroups: [(label: String, keys: [String])]?
    private var activeTemperatureGroups: [(label: String, keys: [String])]?

    mutating func collect() -> SMCReadings {
        guard let connection = activeConnection() else {
            return SMCReadings(
                temperatures: .unavailable("SMC unavailable"),
                fans: .unavailable("SMC unavailable")
            )
        }

        let temperatureResult: (
            readings: [TemperatureReading],
            successfulGroups: [(label: String, keys: [String])]
        )
        if let activeTemperatureGroups {
            temperatureResult = readTemperatures(
                from: activeTemperatureGroups,
                using: connection
            )
        } else {
            let candidateGroups: [(label: String, keys: [String])]
            if let candidateTemperatureGroups {
                candidateGroups = candidateTemperatureGroups
            } else {
                candidateGroups = discoverTemperatureGroups(using: connection)
                self.candidateTemperatureGroups = candidateGroups
            }
            temperatureResult = readTemperatures(
                from: candidateGroups,
                using: connection
            )
            if connection.isUsable, !temperatureResult.successfulGroups.isEmpty {
                self.activeTemperatureGroups = temperatureResult.successfulGroups
            }
        }

        let fans: [FanReading]
        if let rawCount = connection.read("FNum")?.numericValue {
            let fanCount = min(max(Int(rawCount.rounded()), 0), 16)
            fans = (0..<fanCount).compactMap { index in
                guard let rpm = connection.read("F\(index)Ac")?.numericValue,
                      rpm.isFinite, rpm >= 0 else {
                    return nil
                }
                return FanReading(id: index, rpm: rpm)
            }
        } else {
            fans = []
        }

        if !connection.isUsable {
            self.connection = nil
        }

        return SMCReadings(
            temperatures: temperatureResult.readings.isEmpty
                ? .unavailable("Not exposed by this Mac")
                : .available(temperatureResult.readings),
            fans: fans.isEmpty
                ? .unavailable("No fan data")
                : .available(fans)
        )
    }

    private mutating func activeConnection() -> SMCConnection? {
        if let connection, connection.isUsable {
            return connection
        }
        let connection = SMCConnection()
        self.connection = connection
        return connection
    }

    private func readTemperatures(
        from groups: [(label: String, keys: [String])],
        using connection: SMCConnection
    ) -> (
        readings: [TemperatureReading],
        successfulGroups: [(label: String, keys: [String])]
    ) {
        var readings: [TemperatureReading] = []
        var successfulGroups: [(label: String, keys: [String])] = []

        for group in groups {
            var successfulKeys: [String] = []
            var hottest: Double?
            for key in group.keys {
                guard let value = connection.read(key)?.numericValue,
                      value.isFinite, value > 0, value < 130 else {
                    continue
                }
                successfulKeys.append(key)
                hottest = max(hottest ?? value, value)
            }

            if !successfulKeys.isEmpty {
                successfulGroups.append((group.label, successfulKeys))
            }
            if let hottest {
                readings.append(
                    TemperatureReading(
                        id: group.label.lowercased(),
                        label: group.label,
                        celsius: hottest
                    )
                )
            }
        }

        return (readings, successfulGroups)
    }

    private func discoverTemperatureGroups(
        using connection: SMCConnection
    ) -> [(label: String, keys: [String])] {
        let discoveredKeys = connection.temperatureKeys()
        guard !discoveredKeys.isEmpty else {
            return Self.fallbackTemperatureGroups
        }

        let cpuKeys = discoveredKeys.filter(Self.isCPUTemperatureKey)
        let gpuKeys = discoveredKeys.filter(Self.isGPUTemperatureKey)
        return [
            ("CPU", mergedKeys(Self.fallbackTemperatureGroups[0].keys, cpuKeys)),
            ("GPU", mergedKeys(Self.fallbackTemperatureGroups[1].keys, gpuKeys))
        ]
    }

    private static func isCPUTemperatureKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.hasPrefix("tc")
            || normalized.hasPrefix("tp")
            || normalized.hasPrefix("te")
    }

    private static func isGPUTemperatureKey(_ key: String) -> Bool {
        key.lowercased().hasPrefix("tg")
    }

    private func mergedKeys(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs + rhs)).sorted()
    }
}
