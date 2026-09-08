import SwiftUI

@main
struct VoxFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var navigation = Navigation()

    var body: some Scene {
        Window("VoxFlow", id: MainWindowID.main) {
            MainWindow()
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
        }

        MenuBarExtra("VoxFlow", systemImage: "waveform") {
            MenuBarContent()
        }
    }
}
