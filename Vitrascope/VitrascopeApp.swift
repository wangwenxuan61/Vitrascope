import SwiftUI

@main
struct VitrascopeApp: App {
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("menuBarMetric") private var menuMetricRawValue = MetricKind.cpu.rawValue

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Self.isRunningTests)) {
            MenuBarContentView(
                monitor: monitor,
                selectedMetric: Binding(
                    get: { MetricKind(rawValue: menuMetricRawValue) ?? .cpu },
                    set: {
                        menuMetricRawValue = $0.rawValue
                        monitor.setMenuMetric($0)
                    }
                )
            )
        } label: {
            MenuBarLabel(
                snapshot: monitor.snapshot,
                metric: MetricKind(rawValue: menuMetricRawValue) ?? .cpu
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
