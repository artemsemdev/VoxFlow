import SwiftUI
import VoxFlowCore

/// "Add app override" (design 2c / MW-05a): search over installed apps, the app list, "Style in
/// {app}" picker, Cancel/Add.
struct AddAppOverrideSheet: View {
    let viewModel: StylesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add app override").font(.headline)
            TextField("Search installed apps", text: searchBinding)
                .textFieldStyle(.roundedBorder)
            appList
            if viewModel.addAppSheet?.selectedAppName != nil {
                styleRow
            }
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelAddApp() }
                Button("Add") { Task { await viewModel.addOverride() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canAddOverride)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var appList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(viewModel.searchableApps, id: \.bundleID) { app in
                    AppListRow(name: app.name, isSelected: viewModel.addAppSheet?.selectedBundleID == app.bundleID) {
                        viewModel.selectApp(bundleID: app.bundleID, name: app.name)
                    }
                }
            }
        }
        .frame(height: 160)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private var styleRow: some View {
        HStack {
            Text("Style in \(viewModel.addAppSheet?.selectedAppName ?? "")")
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: styleBinding) {
                ForEach(StylesViewModel.overrideStyles, id: \.self) { style in
                    Text(style == .verbatim ? "Verbatim (no cleanup)" : style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var searchBinding: Binding<String> {
        Binding(get: { viewModel.addAppSheet?.search ?? "" }, set: { viewModel.addAppSheet?.search = $0 })
    }

    private var styleBinding: Binding<TextStyle> {
        Binding(get: { viewModel.addAppSheet?.style ?? .default }, set: { viewModel.addAppSheet?.style = $0 })
    }
}

/// One row in the "Add app override" app list — name, selected checkmark.
struct AppListRow: View {
    let name: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Text(name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
