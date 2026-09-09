import SwiftUI
import VoxFlowStorage

/// "Add word" (design 2c / MW-03a, validation MW-03v): Word, Sounds like, Type, the "Also fix it
/// when I type it wrong" checkbox, the static "Say it once to check" helper, Cancel/Add — becomes
/// "Save" while editing an existing entry (`viewModel.sheet.editingID != nil`).
struct AddWordSheet: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add word").font(.headline)
            wordField
            labeledRow("Sounds like") {
                TextField("optional — e.g. \"pree-ya\"", text: soundsLikeBinding)
                    .textFieldStyle(.roundedBorder)
            }
            labeledRow("Type") {
                Picker("", selection: typeBinding) {
                    ForEach(DictionaryEntryType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("Also fix it when I type it wrong", isOn: fixTypingBinding)
                .toggleStyle(.checkbox)
                .padding(.leading, 96)
            helper
                .padding(.leading, 96)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelSheet() }
                Button(isEditing ? "Save" : "Add") { Task { await viewModel.add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canAdd)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isEditing: Bool { viewModel.sheet?.editingID != nil }

    private var wordField: some View {
        labeledRow("Word") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: wordBinding)
                    .textFieldStyle(.roundedBorder)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isDuplicate ? Color.red : Color.clear, lineWidth: 2)
                    )
                if case .duplicate(let existing) = viewModel.validation {
                    HStack {
                        Text("\u{201c}\(existing.word)\u{201d} is already in your dictionary.")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Edit existing") { viewModel.editExisting(existing) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var isDuplicate: Bool {
        if case .duplicate = viewModel.validation { return true }
        return false
    }

    private var helper: some View {
        (Text("Say it once to check: ").foregroundStyle(.secondary)
            + Text("Hold fn and say the word").foregroundStyle(.tint))
            .font(.caption)
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            content()
        }
    }

    private var wordBinding: Binding<String> {
        Binding(get: { viewModel.sheet?.word ?? "" }, set: { viewModel.sheet?.word = $0 })
    }

    private var soundsLikeBinding: Binding<String> {
        Binding(get: { viewModel.sheet?.soundsLike ?? "" }, set: { viewModel.sheet?.soundsLike = $0 })
    }

    private var typeBinding: Binding<DictionaryEntryType> {
        Binding(get: { viewModel.sheet?.type ?? .name }, set: { viewModel.sheet?.type = $0 })
    }

    private var fixTypingBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet?.fixTyping ?? false }, set: { viewModel.sheet?.fixTyping = $0 })
    }
}
