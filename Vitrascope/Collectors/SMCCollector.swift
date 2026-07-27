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
            let bits = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }
}

private final class SMCConnection {
    private static let kernelIndex: UInt32 = 2
    private static let readKeyInfoCommand: UInt8 = 9
    private static let readBytesCommand: UInt8 = 5

    private var connection: io_connect_t = 0

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
        guard let keyCode = Self.fourCharacterCode(key) else { return nil }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        input.key = keyCode
        input.data8 = Self.readKeyInfoCommand

        var result = withUnsafePointer(to: &input) { inputPointer in
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
        guard result == KERN_SUCCESS else { return nil }

        let dataType = output.keyInfo.dataType
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = Self.readBytesCommand
        output = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.stride

        result = withUnsafePointer(to: &input) { inputPointer in
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
        guard result == KERN_SUCCESS else { return nil }

        let byteCount = min(Int(input.keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(byteCount)) }
        return SMCValue(dataType: Self.string(from: dataType), bytes: bytes)
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
    private static let temperatureGroups: [(label: String, keys: [String])] = [
        ("CPU", ["TC0P", "TC0D", "Tp01", "Tp05", "Tp09"]),
        ("GPU", ["TG0P", "TG0D", "Tg05", "Tg0D"])
    ]

    mutating func collect() -> SMCReadings {
        guard let connection = SMCConnection() else {
            return SMCReadings(
                temperatures: .unavailable("SMC unavailable"),
                fans: .unavailable("SMC unavailable")
            )
        }

        let temperatures = Self.temperatureGroups.compactMap { group -> TemperatureReading? in
            let values = group.keys.compactMap { key -> Double? in
                guard let value = connection.read(key)?.numericValue,
                      value.isFinite, value > 0, value < 130 else {
                    return nil
                }
                return value
            }
            guard let hottest = values.max() else { return nil }
            return TemperatureReading(id: group.label.lowercased(), label: group.label, celsius: hottest)
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

        return SMCReadings(
            temperatures: temperatures.isEmpty
                ? .unavailable("Not exposed by this Mac")
                : .available(temperatures),
            fans: fans.isEmpty
                ? .unavailable("No fan data")
                : .available(fans)
        )
    }
}
