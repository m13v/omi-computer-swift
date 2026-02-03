import SwiftUI

struct DailyScoreWidget: View {
    let dailyScore: DailyScore?

    private var score: Double {
        dailyScore?.score ?? 0
    }

    private var hasTasksToday: Bool {
        (dailyScore?.totalTasks ?? 0) > 0
    }

    private var scoreColor: Color {
        // Grey when no tasks (like Flutter)
        if !hasTasksToday {
            return Color.gray
        }
        if score >= 80 {
            return .green
        } else if score >= 60 {
            return Color(red: 0.8, green: 0.8, blue: 0.0) // Lime/Yellow
        } else if score >= 40 {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Daily Score")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
            }

            // Semicircle gauge
            ZStack {
                // Background arc
                SemicircleShape()
                    .stroke(OmiColors.backgroundQuaternary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 140, height: 70)

                // Progress arc
                SemicircleShape()
                    .trim(from: 0, to: min(score / 100, 1.0))
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 140, height: 70)

                // Score text
                VStack(spacing: 2) {
                    Text("\(Int(score))%")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(OmiColors.textPrimary)
                }
                .offset(y: 10)
            }

            // Task count
            if let ds = dailyScore, ds.totalTasks > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(scoreColor)
                    Text("\(ds.completedTasks) of \(ds.totalTasks) tasks completed")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(OmiColors.textTertiary)
                }
            } else {
                Text("No tasks due today")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
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

// MARK: - Semicircle Shape

struct SemicircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width, rect.height * 2) / 2

        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )

        return path
    }
}

#Preview {
    VStack(spacing: 20) {
        DailyScoreWidget(dailyScore: DailyScore(
            score: 85,
            completedTasks: 6,
            totalTasks: 7,
            date: "2026-02-02"
        ))

        DailyScoreWidget(dailyScore: nil)
    }
    .padding()
    .background(OmiColors.backgroundPrimary)
}
