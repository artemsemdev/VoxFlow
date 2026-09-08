import SwiftUI

@main
struct VoxFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private var navigation: Navigation { AppServices.shared.navigation }

    var body: some Scene {
        Window("VoxFlow", id: MainWindowID.main) {
            MainWindow()
                .environment(AppServices.shared)
                .environment(navigation)
        }
        .defaultSize(width: 1120, height: 720)
        .onChange(of: navigation.requestMainWindow) { _, requested in
            guard requested else { return }
            navigation.requestMainWindow = false
            openWindow(id: MainWindowID.main)
        }
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(SidebarPage.allCases) { page in
                    Button(page.title) { navigation.page = page }
                        .keyboardShortcut(page.keyEquivalent, modifiers: .command)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    // The result view (if one is showing) has to close first — otherwise the file
                    // importer would appear behind it with no visible effect until the user backs
                    // out on their own.
                    AppServices.shared.filesViewModel.closeResult()
                    navigation.page = .files
                    navigation.requestFileImport = true
                }
                .keyboardShortcut("o")
            }
        }

        MenuBarExtra("VoxFlow", systemImage: "waveform") {
            MenuBarContent()
        }
    }
}
