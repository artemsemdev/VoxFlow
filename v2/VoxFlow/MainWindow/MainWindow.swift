import SwiftUI

/// Main window content (design 1c): sidebar + detail. ⌘1…⌘7 live in VoxFlowApp's commands.
struct MainWindow: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            SidebarView(selection: $navigation.page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            if navigation.page == .files {
                FilesPage()
            } else {
                PlaceholderPageView(page: navigation.page)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
