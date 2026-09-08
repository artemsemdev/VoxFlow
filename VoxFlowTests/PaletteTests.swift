import SwiftUI
import Testing
@testable import VoxFlow

@Suite("Palette")
struct PaletteTests {
    @Test("six accent colors, all distinct")
    func accentsDistinct() {
        let colors = Palette.AccentName.allCases.map { Palette.accent($0).description }
        #expect(colors.count == 6)
        #expect(Set(colors).count == 6)
    }
}
