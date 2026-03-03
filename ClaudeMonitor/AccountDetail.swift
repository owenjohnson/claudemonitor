import SwiftUI
import AppKit

struct LiveAccountDetail: View {
    let accountUsage: AccountUsage

    var body: some View {
        VStack(spacing: 8) {
            if accountUsage.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if let error = accountUsage.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 8)
            } else if let usage = accountUsage.usage {
                UsageRow(
                    title: "Session",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: Color.forUtilization(usage.sessionPercentage),
                    tooltipText: "5-hour rolling window"
                )
                UsageRow(
                    title: "Weekly",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: Color.forUtilization(usage.weeklyPercentage),
                    tooltipText: "7-day rolling window"
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        percentage: sonnetPct,
                        resetsAt: usage.sonnetResetsAt,
                        color: Color.forUtilization(sonnetPct),
                        tooltipText: "Model-specific limit"
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct StaleAccountDetail: View {
    let accountUsage: AccountUsage

    var body: some View {
        let staleColor = Color(NSColor.secondaryLabelColor)
        VStack(spacing: 8) {
            if let usage = accountUsage.usage {
                UsageRow(
                    title: "Session",
                    percentage: usage.sessionPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    tooltipText: "5-hour rolling window"
                )
                UsageRow(
                    title: "Weekly",
                    percentage: usage.weeklyPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    tooltipText: "7-day rolling window"
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        percentage: sonnetPct,
                        resetsAt: nil,
                        color: staleColor,
                        tooltipText: "Model-specific limit"
                    )
                }
            } else {
                Text("No usage data available for this account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            // Layer 3 staleness signal: timestamp
            if let updated = accountUsage.lastUpdated {
                HStack {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
    }
}
