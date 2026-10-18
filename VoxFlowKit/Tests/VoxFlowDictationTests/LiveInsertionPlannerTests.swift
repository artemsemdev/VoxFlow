import Testing
@testable import VoxFlowDictation

@Suite("Live insertion planner")
struct LiveInsertionPlannerTests {
    @Test("two cumulative windows become two appends whose text is the final snapshot")
    func cumulativeWindows() {
        var planner = LiveInsertionPlanner()
        var writes: [String] = []

        let first = planner.plan(for: "hello")
        #expect(first.edit == .append(text: "hello", atUTF16Offset: 0))
        #expect(planner.committedText.isEmpty)
        writes.append("hello")
        let appliedFirst = planner.didApply(first)
        #expect(appliedFirst)

        let second = planner.plan(for: "hello world")
        #expect(second.edit == .append(text: " world", atUTF16Offset: 5))
        writes.append(" world")
        let appliedSecond = planner.didApply(second)
        #expect(appliedSecond)
        #expect(writes.joined() == planner.committedText)
        #expect(planner.committedText == "hello world")
    }

    @Test("a duplicate cumulative snapshot needs no external write")
    func duplicate() {
        var planner = LiveInsertionPlanner()
        let initial = planner.plan(for: "already inserted")
        let appliedInitial = planner.didApply(initial)
        #expect(appliedInitial)

        let duplicate = planner.plan(for: "already inserted")
        #expect(duplicate.edit == .none)
        let appliedDuplicate = planner.didApply(duplicate)
        #expect(appliedDuplicate)
        #expect(planner.committedText == "already inserted")
    }

    @Test("a corrected tail starts and ends on UTF-16 grapheme boundaries")
    func unicodeCorrection() {
        var planner = LiveInsertionPlanner()
        let original = "A 👩🏽‍💻 cafe\u{301}!"
        let initial = planner.plan(for: original)
        let appliedInitial = planner.didApply(initial)
        #expect(appliedInitial)

        let prefix = "A 👩🏽‍💻 caf"
        let corrected = planner.plan(for: prefix + "é?")
        #expect(corrected.edit == .replaceTail(
            utf16Range: prefix.utf16.count..<original.utf16.count,
            with: "é?"
        ))
        #expect(planner.committedText == original)
        let appliedCorrection = planner.didApply(corrected)
        #expect(appliedCorrection)
        #expect(planner.committedText == prefix + "é?")
    }

    @Test("failed writes do not advance the next plan's baseline")
    func failedWrite() {
        let planner = LiveInsertionPlanner()
        _ = planner.plan(for: "failed")

        #expect(planner.committedText.isEmpty)
        #expect(planner.plan(for: "retry").edit == .append(text: "retry", atUTF16Offset: 0))
    }

    @Test("a plan from before reset cannot commit into the next empty capture")
    func rejectsPlanAfterReset() {
        var planner = LiveInsertionPlanner()
        let stale = planner.plan(for: "old capture")
        planner.reset()
        let appliedStale = planner.didApply(stale)
        #expect(!appliedStale)
        #expect(planner.committedText.isEmpty)
    }

    @Test("a plan belongs to the planner that created it")
    func rejectsForeignPlan() {
        let foreign = LiveInsertionPlanner().plan(for: "other capture")
        var planner = LiveInsertionPlanner()
        let appliedForeign = planner.didApply(foreign)
        #expect(!appliedForeign)
        #expect(planner.committedText.isEmpty)
    }

    @Test("even a no-op acknowledgement invalidates competing plans")
    func rejectsCompetingPlan() {
        var planner = LiveInsertionPlanner()
        let earlier = planner.plan(for: "stale")
        let noOp = planner.plan(for: "")
        let appliedNoOp = planner.didApply(noOp)
        #expect(appliedNoOp)
        let appliedCompeting = planner.didApply(earlier)
        #expect(!appliedCompeting)
        let appliedAgain = planner.didApply(noOp)
        #expect(!appliedAgain)
        #expect(planner.committedText.isEmpty)
    }

    @Test("returning to the same text does not revive an old plan")
    func rejectsPlanAfterBaselineReturns() {
        var planner = LiveInsertionPlanner()
        let stale = planner.plan(for: "stale")
        let appliedTemporary = planner.didApply(planner.plan(for: "temporary"))
        #expect(appliedTemporary)
        let appliedEmpty = planner.didApply(planner.plan(for: ""))
        #expect(appliedEmpty)
        let appliedStale = planner.didApply(stale)
        #expect(!appliedStale)
        #expect(planner.committedText.isEmpty)
    }

    @Test("reset starts the next capture at offset zero")
    func reset() {
        var planner = LiveInsertionPlanner()
        let first = planner.plan(for: "first capture")
        let appliedFirst = planner.didApply(first)
        #expect(appliedFirst)

        planner.reset()

        #expect(planner.committedText.isEmpty)
        #expect(planner.plan(for: "next").edit == .append(text: "next", atUTF16Offset: 0))
    }
}
