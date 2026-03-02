import SwiftUI
import AppKit

enum UsageRowStyle { case card, inline }

struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    var style: UsageRowStyle = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title) usage")
                .accessibilityValue("\(percentage) percent")
            }
            .frame(height: 8)

            // Reset time
            if let resetsAt = resetsAt {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Resets \(formatTimeRemaining(resetsAt))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(style == .card ? 12 : 8)
        .background(style == .card ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .cornerRadius(style == .card ? 8 : 0)
    }

    func formatTimeRemaining(_ date: Date) -> String {
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
