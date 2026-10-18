import SwiftUI

/// "New snippet" (design 2c / MW-04a, validation MW-04v): Say + the "spoken as" hint, Insert (with
/// the `cursor` chip) + its helper line, the "Only in {app}" checkbox and picker, Cancel/Save —
/// "Save" throughout, editing or not (the canvas's own "New snippet" sheet already says "Save").
struct NewSnippetSheet: View {
    let viewModel: SnippetsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New snippet").font(.headline)
            sayField
            insertField
            helper
                .padding(.leading, 84)
            onlyInRow
                .padding(.leading, 84)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelSheet() }
                Button("Save") { Task { await viewModel.save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var sayField: some View {
        labeledRow("Say") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: sayBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isInvalid ? Color.red : Color.clear, lineWidth: 2)
                    )
                if let hint = viewModel.spokenHint, !isInvalid {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                validationText
            }
        }
    }

    @ViewBuilder
    private var validationText: some View {
        switch viewModel.validation {
        case .duplicate(_, let message, let suggestion):
            VStack(alignment: .leading, spacing: 2) {
                Text(message).foregroundStyle(.red)
                Text(suggestion).foregroundStyle(.secondary)
            }
            .font(.caption)
        case .invalid(let suggestion):
            Text(suggestion).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var isInvalid: Bool {
        switch viewModel.validation {
        case .duplicate, .invalid: true
        default: false
        }
    }

    private var insertField: some View {
        labeledRow("Insert") {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: bodyBinding)
                    .font(.body)
                    .frame(height: 84)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
                Button {
                    viewModel.insertCursorPlaceholder()
                } label: {
                    Text("cursor")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    private var helper: some View {
        Text("Insert **cursor** where dictation should continue. Placeholders: **date**, **clipboard**, **app**.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var onlyInRow: some View {
        HStack(spacing: 10) {
            Toggle(onlyInLabel, isOn: onlyInBinding)
                .toggleStyle(.checkbox)
            if viewModel.sheet?.onlyIn == true {
                Picker("", selection: appBinding) {
                    ForEach(viewModel.apps, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    /// "Only in an app" (no app chosen yet) is implementation-authored copy (review M4) — the canvas
    /// only shows the post-selection state ("Only in Slack"); flagged for an explicit owner call
    /// rather than silently assumed. Kept because the checkbox needs *some* label before a Picker
    /// selection exists.
    private var onlyInLabel: String {
        if let name = viewModel.sheet?.onlyInAppName { "Only in \(name)" } else { "Only in an app" }
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            content()
        }
    }

    private var sayBinding: Binding<String> {
        Binding(get: { viewModel.sheet?.trigger ?? "" }, set: { viewModel.sheet?.trigger = $0 })
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { viewModel.sheet?.body ?? "" }, set: { viewModel.sheet?.body = $0 })
    }

    private var onlyInBinding: Binding<Bool> {
        Binding(get: { viewModel.sheet?.onlyIn ?? false }, set: { viewModel.setOnlyIn($0) })
    }

    private var appBinding: Binding<String> {
        Binding(get: { viewModel.sheet?.onlyInBundleID ?? "" }, set: { viewModel.chooseOnlyInApp(bundleID: $0) })
    }
}
