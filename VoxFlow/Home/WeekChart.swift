import SwiftUI
import VoxFlowStorage

/// The "This week" card (design MW-01, ruling 1): 7 bars sized relative to the week's max day, a
/// day-of-week letter under each, today's bar and letter accent-coloured.
struct WeekChart: View {
    /// Oldest first, ending today — `StatsService.week` / `HomeViewModel.week`.
    let days: [DayWords]
    let totalText: String
    let calendar: Calendar

    private static let barWidth: CGFloat = 22
    private static let barMaxHeight: CGFloat = 64
    private static let barMinHeight: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("This week").font(.headline)
                Spacer()
                Text(totalText).font(.headline)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let isToday = index == days.count - 1
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isToday ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: Self.barWidth, height: barHeight(for: day))
                        Text(Self.letter(for: day.date, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                    }
                }
            }
            .frame(height: Self.barMaxHeight + 20, alignment: .bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Every bar's height relative to the week's busiest day; a day with 0 words still draws a thin
    /// sliver (`barMinHeight`) rather than vanishing entirely.
    private func barHeight(for day: DayWords) -> CGFloat {
        let maxWords = max(days.map(\.words).max() ?? 0, 1)
        let fraction = CGFloat(day.words) / CGFloat(maxWords)
        return max(Self.barMinHeight, Self.barMaxHeight * fraction)
    }

    /// Calendar's very-short weekday symbol for `date`'s weekday. `veryShortWeekdaySymbols` is
    /// 0-indexed from Sunday; `Calendar.component(.weekday:)` is 1-indexed from Sunday — off by one.
    static func letter(for date: Date, calendar: Calendar) -> String {
        let weekday = calendar.component(.weekday, from: date)
        return calendar.veryShortWeekdaySymbols[weekday - 1]
    }
}
