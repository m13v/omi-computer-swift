import SwiftUI

struct FocusSummaryWidget: View {
    let stats: FocusDayStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Focus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
            }

            // Stats row - all in one line
            HStack(spacing: 10) {
                FocusStatCard(
                    title: "Focus Time",
                    value: "\(stats.focusedMinutes)",
                    unit: "min",
                    icon: "eye.fill",
                    color: Color.green
                )

                FocusStatCard(
                    title: "Distracted",
                    value: "\(stats.distractedMinutes)",
                    unit: "min",
                    icon: "eye.slash.fill",
                    color: Color.orange
                )

                FocusStatCard(
                    title: "Focus Rate",
                    value: String(format: "%.0f", stats.focusRate),
                    unit: "%",
                    icon: "chart.pie.fill",
                    color: OmiColors.info
                )

                FocusStatCard(
                    title: "Sessions",
                    value: "\(stats.sessionCount)",
                    unit: "",
                    icon: "clock.fill",
                    color: OmiColors.info
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(OmiColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(OmiColors.backgroundQuaternary.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - Stat Card

struct FocusStatCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textSecondary)

                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(OmiColors.textPrimary)

                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
            }

            Text(title)
                .font(.system(size: 10))
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundTertiary.opacity(0.6))
        )
    }
}

#Preview {
    FocusSummaryWidget(stats: FocusDayStats(
        date: Date(),
        focusedMinutes: 45,
        distractedMinutes: 15,
        sessionCount: 8,
        focusedCount: 6,
        distractedCount: 2,
        topDistractions: []
    ))
    .padding()
    .background(OmiColors.backgroundPrimary)
}
