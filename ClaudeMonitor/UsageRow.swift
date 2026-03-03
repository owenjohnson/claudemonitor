import SwiftUI

struct UsageRow: View {
    let title: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    var tooltipText: String? = nil

    private var accessibilityValueText: String {
        "\(percentage) percent"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.primary)

            if percentage >= 70, let resetsAt = resetsAt {
                Text(formatTimeRemaining(resetsAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(percentage)%")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
        .help(tooltipText ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(accessibilityValueText)
    }

    private func formatTimeRemaining(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "soon" }
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "in \(days)d \(remainingHours)h"
        }
        return "in \(hours)h \(minutes)m"
    }
}
