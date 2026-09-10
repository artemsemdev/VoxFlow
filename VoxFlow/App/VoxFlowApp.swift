import SwiftUI

@main
struct VoxFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private var navigation: Navigation { AppServices.shared.navigation }

    /// ST-01 "Show in menu bar" — `MenuBarExtra(isInserted:)` reads/writes this directly, so
    /// toggling it in Settings › General removes/restores the menu bar item live.
    private var showInMenuBar: Binding<Bool> {
        Binding(get: { SettingsServices.shared.generalSettings.showInMenuBar },
                set: { SettingsServices.shared.generalSettings.showInMenuBar = $0 })
    }

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
        .onChange(of: navigation.requestOnboarding) { _, requested in
            guard requested else { return }
            navigation.requestOnboarding = false
            openWindow(id: OnboardingWindowID.onboarding)
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
                // ⇧⌘O (review fix, Task 4/5): plain ⌘O is "Open VoxFlow" below (the menu bar
                // dropdown's own item, ruling 9) — the two are genuinely different actions and can't
                // share one keystroke, so File › Open… moves off it instead of silently losing to
                // whichever `CommandGroup` AppKit resolves ties toward.
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Ruling 9: the menu bar dropdown's own items ("Open VoxFlow ⌘O", "History ⌥⌘H",
            // "Settings… ⌘,") declared app-wide too, so they work whether or not the dropdown is
            // open. "Quit VoxFlow ⌘Q" needs no separate declaration — every macOS app already gets
            // that for free in its own App menu.
            CommandGroup(after: .appInfo) {
                Button("Open VoxFlow") { navigation.requestMainWindow = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("History") {
                    navigation.page = .history
                    navigation.requestMainWindow = true
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    navigation.page = .settings
                    navigation.requestMainWindow = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // MB-01/MB-02 (design page 11/8): a `.window`-style dropdown (`MenuBarContent` →
        // `MenuBarView`) instead of a plain `Menu`, behind a code-drawn template glyph
        // (`MenuBarGlyph` — ruling 6: "until #141 ships the icon asset").
        MenuBarExtra(isInserted: showInMenuBar) {
            MenuBarContent()
        } label: {
            Image(nsImage: MenuBarGlyph.image)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to VoxFlow", id: OnboardingWindowID.onboarding) {
            OnboardingWindow()
                .environment(AppServices.shared)
        }
        .windowResizability(.contentSize)
        // D-1: one set of chrome — real traffic lights, no titlebar strip/title text above the
        // content, matching the mock (`OnboardingContentView` reserves clearance for them but no
        // longer hand-draws its own).
        .windowStyle(.hiddenTitleBar)
    }
}
