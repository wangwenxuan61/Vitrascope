import SwiftUI

struct MetricCard<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    let content: Content

    init(
        title: String,
        systemImage: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .tint(accent)

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.52), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

struct UnavailableReadingView: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.circle")
            Text(message)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 34)
    }
}

struct StatLabel: View {
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
    }
}
