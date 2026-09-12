import SwiftUI
import VoxFlowStorage

/// Canvas 2e: equal transcript columns joined to the compact row.
struct HistoryDetailView: View {
    let record: DictationRecord
    @Bindable var model: HistoryViewModel
    var addToDictionary: @MainActor (String) -> Void = { _ in }
    @FocusState private var editorFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var colors: HistoryCardColors { HistoryCardColors(scheme: colorScheme) }
    private var annotationPresentation: HistoryAnnotationPresentation {
        HistoryAnnotationPresentation(record: record)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rawColumn
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(HistoryViewModel.detailHeader(for: record))
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(0.46)
                        .foregroundStyle(colors.secondaryText)
                    Spacer()
                    editActions
                }
                if model.editingID == record.id {
                    TextEditor(text: $model.editedText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 100)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5)))
                        .focused($editorFocused)
                        .onAppear { editorFocused = true }
                        .onExitCommand { model.cancelEdit() }
                        .disabled(model.isSavingEdit)
                        .accessibilityLabel("Edit inserted text")
                    if let error = model.editError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    TranscriptWordView(text: HistoryViewModel.displayText(for: record), addToDictionary: addToDictionary)
                }
                Text("Right-click a word → Add to Dictionary · Audio was not saved")
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.surface)
        .overlay { colors.separator.frame(width: 1).allowsHitTesting(false) }
        .overlay(alignment: .top) { colors.separator.frame(height: 1).allowsHitTesting(false) }
    }

    private var editActions: some View {
        HStack(spacing: 10) {
            if model.editingID == record.id {
                Button("Cancel") { model.cancelEdit() }
                    .disabled(model.isSavingEdit)
                Button(model.editSaveTitle) { Task { await model.saveEdit() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSaveEdit)
            } else {
                Button("Edit") { model.beginEditing(record) }
                    .disabled(!model.canEdit(record))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.tint)
    }

    private var rawColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT YOU SAID")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.46)
                .foregroundStyle(colors.secondaryText)
            Text(annotationPresentation.attributedRawText(
                displayText: HistoryViewModel.displayRawText(for: record),
                rawColor: colors.rawText,
                accentColor: .accentColor))
                .font(.system(size: 13)).lineSpacing(5.2)
            if !annotationPresentation.badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(annotationPresentation.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(colors.neutralAction, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The light/dark card surfaces and hairlines specified by canvas 2e.
struct HistoryCardColors {
    let scheme: ColorScheme
    private var ink: Color { scheme == .dark ? .white : .black }
    var surface: Color { scheme == .dark ? Color(red: 42 / 255, green: 42 / 255, blue: 46 / 255) : .white }
    var header: Color { ink.opacity(scheme == .dark ? 0.03 : 0.02) }
    var border: Color { ink.opacity(0.07) }
    var separator: Color { ink.opacity(scheme == .dark ? 0.07 : 0.06) }
    var neutralAction: Color { ink.opacity(scheme == .dark ? 0.08 : 0.05) }
    var secondaryText: Color { ink.opacity(0.5) }
    var rawText: Color { ink.opacity(scheme == .dark ? 0.72 : 0.7) }
}
