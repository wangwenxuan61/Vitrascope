import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @Binding var selectedMetric: MetricKind

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.07, blue: 0.14),
                    Color(red: 0.07, green: 0.055, blue: 0.18),
                    Color(red: 0.025, green: 0.11, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    header

                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            CPUCard(reading: monitor.snapshot.cpu, history: monitor.history)
                            MemoryCard(reading: monitor.snapshot.memory, history: monitor.history)
                            GPUCard(reading: monitor.snapshot.gpuPercent, history: monitor.history)
                            ThermalCard(
                                thermalState: monitor.snapshot.thermalState,
                                temperatures: monitor.snapshot.temperatures,
                                fans: monitor.snapshot.fans
                            )
                        }
                    }

                    footer
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 380, height: 520)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.18))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 34, height: 34)
            .glassEffect(.regular, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Vitrascope")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Live system monitor")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(thermalColor)
                .frame(width: 7, height: 7)
                .shadow(color: thermalColor.opacity(0.7), radius: 4)
                .accessibilityLabel("Thermal state \(monitor.snapshot.thermalState.rawValue)")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("Menu Bar", selection: $selectedMetric) {
                ForEach(MetricKind.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Menu bar metric")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
            .keyboardShortcut("q")
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var thermalColor: Color {
        switch monitor.snapshot.thermalState {
        case .nominal: .mint
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        case .unknown: .gray
        }
    }
}
