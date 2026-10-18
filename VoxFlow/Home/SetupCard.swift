import SwiftUI

/// The "Setup" card (design MW-01e, ruling 3/3e): a green check + status per row when satisfied, a
/// red check + action link otherwise. Shown standalone on first run, or layered onto a returning
/// MW-01 whenever a permission is missing (ruling 3e) — same view either way.
struct SetupCard: View {
    let rows: [SetupRow]
    let perform: (SetupRow.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Setup")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    SetupRowLine(row: row, perform: perform)
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SetupRowLine: View {
    let row: SetupRow
    let perform: (SetupRow.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.kind == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(row.kind == .ok ? Palette.onDevice : .red)
            Text(row.label)
            Spacer()
            if row.isLink {
                Button(row.valueText) { perform(row.action) }
                    .buttonStyle(.plain)
                    .foregroundStyle(row.kind == .attention ? Color.red : Color.accentColor)
            } else {
                Text(row.valueText).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
