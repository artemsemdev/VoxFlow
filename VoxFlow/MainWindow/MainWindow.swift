import SwiftUI

/// Main window content (design 1c): sidebar + detail. ⌘1…⌘7 live in VoxFlowApp's commands.
struct MainWindow: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            SidebarView(selection: $navigation.page, requestBytes: services.requestBytes)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch navigation.page {
            case .home: HomePage()
            case .files: FilesPage()
            case .history: HistoryPage()
            case .dictionary: DictionaryPage()
            case .snippets: SnippetsPage()
            case .styles: StylesPage()
            case .settings: SettingsPage()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: navigation.requestFileImport) { _, requested in
            if requested { navigation.page = .files }
        }
    }
}
