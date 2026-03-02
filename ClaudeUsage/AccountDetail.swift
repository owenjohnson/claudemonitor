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
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: Color.forUtilization(usage.sessionPercentage),
                    style: .inline
                )
                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: Color.forUtilization(usage.weeklyPercentage),
                    style: .inline
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        subtitle: "Model-specific",
                        percentage: sonnetPct,
                        resetsAt: usage.sonnetResetsAt,
                        color: Color.forUtilization(sonnetPct),
                        style: .inline
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
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    style: .inline
                )
                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    style: .inline
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        subtitle: "Model-specific",
                        percentage: sonnetPct,
                        resetsAt: nil,
                        color: staleColor,
                        style: .inline
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
