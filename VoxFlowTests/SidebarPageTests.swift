import Testing
@testable import VoxFlow

@Suite("SidebarPage")
struct SidebarPageTests {
    @Test("seven pages in the order the design's sidebar shows them")
    func orderMatchesDesign() {
        #expect(SidebarPage.allCases.map(\.title) == [
            "Home", "History", "Dictionary", "Snippets", "Styles", "Files", "Settings",
        ])
    }

    @Test("⌘1…⌘7 map to the pages in sidebar order")
    func shortcutsAreSequential() {
        #expect(SidebarPage.allCases.map(\.shortcutNumber) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test("every page has a distinct SF Symbol")
    func symbolsAreDistinct() {
        let symbols = SidebarPage.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { $0.isEmpty == false })
    }

    @Test("home is the default page")
    func defaultPage() {
        #expect(SidebarPage.default == .home)
    }

    @Test("key equivalents are the digits 1…7")
    func keyEquivalents() {
        #expect(SidebarPage.allCases.map { String($0.keyEquivalent.character) } == ["1", "2", "3", "4", "5", "6", "7"])
    }
}
