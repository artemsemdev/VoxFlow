import Testing
import VoxFlowCore
@testable import VoxFlowStyling

@Suite("StyleResolver")
struct StyleResolverTests {
    @Test("no bundle id falls back to the default style")
    func noBundleID() {
        let resolved = StyleResolver.resolve(
            default: .casual,
            overrides: ["com.example.mail": .formal],
            bundleID: nil
        )
        #expect(resolved == .casual)
    }

    @Test("bundle id with no override falls back to the default style")
    func noOverrideForBundleID() {
        let resolved = StyleResolver.resolve(
            default: .casual,
            overrides: ["com.example.mail": .formal],
            bundleID: "com.example.notes"
        )
        #expect(resolved == .casual)
    }

    @Test("a matching override wins over the default style")
    func overrideWins() {
        let resolved = StyleResolver.resolve(
            default: .casual,
            overrides: ["com.example.mail": .formal],
            bundleID: "com.example.mail"
        )
        #expect(resolved == .formal)
    }

    @Test("empty overrides always fall back to the default")
    func emptyOverrides() {
        let resolved = StyleResolver.resolve(
            default: .veryCasual,
            overrides: [:],
            bundleID: "com.example.mail"
        )
        #expect(resolved == .veryCasual)
    }
}
