import SwiftUI
import AppKit

struct AccountDetail: View {
    let accountUsage: AccountUsage

    private var isStale: Bool {
        !accountUsage.isCurrentAccount && !accountUsage.isActivelyRefreshing
    }

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
                let color = isStale ? Color(NSColor.secondaryLabelColor) : Color.forUtilization(usage.sessionPercentage)
                let weeklyColor = isStale ? Color(NSColor.secondaryLabelColor) : Color.forUtilization(usage.weeklyPercentage)

                UsageRow(
                    title: "Session",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: color,
                    tooltipText: "5-hour rolling window"
                )
                UsageRow(
                    title: "Weekly",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: weeklyColor,
                    tooltipText: "7-day rolling window"
                )
                if let sonnetPct = usage.sonnetPercentage {
                    let sonnetColor = isStale ? Color(NSColor.secondaryLabelColor) : Color.forUtilization(sonnetPct)
                    UsageRow(
                        title: "Sonnet Only",
                        percentage: sonnetPct,
                        resetsAt: usage.sonnetResetsAt,
                        color: sonnetColor,
                        tooltipText: "Model-specific limit"
                    )
                }

                if isStale, let updated = accountUsage.lastUpdated {
                    HStack {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            } else if isStale {
                Text("No usage data available for this account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
    }
}
