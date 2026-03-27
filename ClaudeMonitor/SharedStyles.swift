import SwiftUI
import AppKit

// MARK: - Color Utilities (D6)

extension Color {
    /// Single source of truth for utilization color thresholds.
    /// 90%+ → red, 70%+ → orange, otherwise → green.
    static func forUtilization(_ percentage: Int) -> Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .green
    }
}

// MARK: - LiveIndicator

struct LiveIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .animation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear { isPulsing = true }
            Text("Live")
                .font(.caption)
                .foregroundColor(.green)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live account")
    }
}

// MARK: - CachedBadge (Active: cached token, still refreshing)

struct CachedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
            Text("Active")
                .font(.caption)
                .foregroundColor(.blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Active account with cached token")
    }
}

// MARK: - StaleBadge (C3)

struct StaleBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Text("Stale")
                .font(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stale account")
    }
}
