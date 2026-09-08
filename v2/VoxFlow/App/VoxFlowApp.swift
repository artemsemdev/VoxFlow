import SwiftUI

@main
struct VoxFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var navigation: Navigation { AppServices.shared.navigation }

    var body: some Scene {
        Window("VoxFlow", id: MainWindowID.main) {
            MainWindow()
                .environment(AppServices.shared)
                .environment(navigation)
        }
        .defaultSize(width: 1120, height: 720)
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
                    navigation.requestFileImport = true
                    navigation.page = .files
                }
                .keyboardShortcut("o")
            }
        }

        MenuBarExtra("VoxFlow", systemImage: "waveform") {
            MenuBarContent()
        }
    }
}
