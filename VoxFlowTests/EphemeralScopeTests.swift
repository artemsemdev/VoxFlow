import Testing
@testable import VoxFlow

@Suite("EphemeralScope")
struct EphemeralScopeTests {
    @Test("inactive until entered; leaving balances entering")
    func enterLeave() {
        let scope = EphemeralScope()
        #expect(scope.isActive == false)
        scope.enter()
        #expect(scope.isActive)
        scope.leave()
        #expect(scope.isActive == false)
    }

    @Test("nested/overlapping scopes: stays active until every enter() has a matching leave()")
    func nestedScopes() {
        let scope = EphemeralScope()
        scope.enter()   // e.g. onboarding's Try It step opens
        scope.enter()   // e.g. History's scratchpad opens while onboarding is also up
        #expect(scope.isActive)
        scope.leave()   // one of the two closes
        #expect(scope.isActive)   // the other is still up
        scope.leave()
        #expect(scope.isActive == false)
    }

    @Test("an unmatched leave() is a no-op, not a negative count that corrupts a later enter()")
    func unmatchedLeaveIsHarmless() {
        let scope = EphemeralScope()
        scope.leave()
        scope.leave()
        #expect(scope.isActive == false)
        scope.enter()
        #expect(scope.isActive)
        scope.leave()
        #expect(scope.isActive == false)
    }
}
