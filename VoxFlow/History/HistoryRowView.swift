import SwiftUI
import VoxFlowStorage

/// One History row (design MW-02 / 2e): coloured app-initial tile, single-line text, meta line, and
/// hover/selection actions (Copy, the phase-5 "Re-style ▾", Delete). Tapping toggles the inline
/// detail (design MW-02d).
struct HistoryRowView: View {
    let record: DictationRecord
    let model: HistoryViewModel
    @State private var isHovering = false
    @State private var isRestyleShown = false
    @Environment(\.colorScheme) private var colorScheme

    private var isExpanded: Bool { model.expandedID == record.id }
    private var colors: HistoryCardColors { HistoryCardColors(scheme: colorScheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 4) {
                Text(HistoryViewModel.displayText(for: record))
                    .font(.system(size: 13))
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)
                    .foregroundStyle(record.isUnreadable ? .secondary : .primary)
                Text(HistoryViewModel.metaLine(for: record))
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondaryText)
            }
            Spacer(minLength: 12)
            if isHovering || isExpanded {
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(isExpanded ? colors.header : Color.clear)
        .onTapGesture { model.toggleExpanded(id: record.id) }
        .onHover { isHovering = $0 }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(HistoryViewModel.color(for: record.appName))
            .frame(width: 28, height: 28)
            .overlay(
                Text(HistoryViewModel.initial(for: record.appName))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Copy") { model.copy(record) }
                .buttonStyle(HistoryRowActionStyle(background: colors.neutralAction))
            // Re-style (design 2e, MW-02s): opens a popover of the four styles under the button.
            // SwiftUI's `.popover` already fades in/out and dismisses on outside click/Esc — no
            // custom animation here.
            Button { isRestyleShown = true } label: {
                HStack(spacing: 2) {
                    Text("Re-style")
                    if model.restylingID == record.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
            }
            .buttonStyle(HistoryRowActionStyle(background: isExpanded ? .accentColor : colors.neutralAction,
                                               foreground: isExpanded ? .white : .primary))
            .disabled(model.editingID != nil)
            .popover(isPresented: $isRestyleShown, arrowEdge: .bottom) {
                RestyleMenuView(record: record, model: model)
            }
            Button("Delete") { model.delete(record) }
                .buttonStyle(HistoryRowActionStyle(background: colors.neutralAction))
        }
        .font(.system(size: 12))
        .disabled(model.restylingID != nil || model.isSavingEdit)
    }
}

private struct HistoryRowActionStyle: ButtonStyle {
    let background: Color
    var foreground: Color = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
