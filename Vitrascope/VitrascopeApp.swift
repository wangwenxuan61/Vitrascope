import SwiftUI

@main
struct VitrascopeApp: App {
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("menuBarMetric") private var menuMetricRawValue = MetricKind.cpu.rawValue

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                monitor: monitor,
                selectedMetric: Binding(
                    get: { MetricKind(rawValue: menuMetricRawValue) ?? .cpu },
                    set: { menuMetricRawValue = $0.rawValue }
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
}
