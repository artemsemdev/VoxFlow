import SwiftUI

/// The "Recent" card (design MW-01, ruling 1): header + "See all", then up to 4 rows — a coloured
/// initial tile (`HistoryRowView`'s look), the dictation's text, and its meta line.
struct RecentList: View {
    let rows: [HomeRecentRow]
    let seeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("See all", action: seeAll)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    RecentRowLine(row: row)
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RecentRowLine: View {
    let row: HomeRecentRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.color)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(row.initial)
                        .font(.headline)
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(row.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
