import SwiftUI

/// One of Home's four top stat cards (design MW-01/MW-01e, ruling 1): a label, a large value, and
/// an optional unit next to it ("18" + "min").
struct StatCard: View {
    let model: HomeStatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.value)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(model.value == "—" ? .secondary : .primary)
                if let unit = model.unit {
                    Text(unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
