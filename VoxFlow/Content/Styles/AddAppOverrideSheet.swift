import AppKit
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
                ForEach(viewModel.searchableApps) { app in
                    AppListRow(app: app, isSelected: viewModel.addAppSheet?.selectedBundleID == app.bundleID) {
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

/// One row in the "Add app override" app list (design MW-05a, brief: "list (name + hint)") — app
/// icon, name, a trailing hint (the hosting browser for a browser-installed "web app" like "Google
/// Docs … Chrome", or the bundle id in secondary colour for a native app), selected checkmark.
struct AppListRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                icon
                Text(app.name)
                Spacer(minLength: 8)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    /// Loaded on demand from `app.url` (not cached in `InstalledApp` — see its doc comment) via
    /// `NSWorkspace.shared.icon(forFile:)`; falls back to a generic glyph when there's no URL (e.g.
    /// a fake used in a test/render).
    private var icon: some View {
        Group {
            if let url = app.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// The hosting browser for a browser-installed "web app" ("Chrome", "Microsoft Edge"), or the
    /// bundle id for a native app (design must-fix: the canvas's "Google Docs … Chrome" row).
    private var hint: String {
        app.hostAppName ?? app.bundleID
    }
}
