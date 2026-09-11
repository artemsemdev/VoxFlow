import Foundation
import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("History filters", .timeLimit(.minutes(1)))
@MainActor
struct HistoryFilterTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ day: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func model(_ h: HistoryViewModelTests.Harness) -> HistoryViewModel {
        let now = date(11)
        return HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                clock: h.clock, pasteboard: FakePasteboard(), calendar: calendar, now: { now })
    }

    @Test("the default This week filter excludes old history without claiming the store is empty")
    func defaultDateFilter() async {
        let h = HistoryViewModelTests.Harness()
        await h.seed(1) // A retained 1970 record, far outside the current calendar week.
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard())
        await vm.load()
        #expect(vm.records.isEmpty)
        #expect(vm.emptyState == .noResults(""))
    }

    @Test("calendar ranges include their start and exclude the next interval", arguments: HistoryViewModel.DateRange.allCases)
    func dateBoundaries(_ range: HistoryViewModel.DateRange) async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        for day in [1, 6, 7, 11, 12, 14] {
            _ = try h.service.store!.insert(HistoryViewModelTests.draft("day \(day)", at: date(day)))
        }
        _ = try h.service.store!.insert(HistoryViewModelTests.draft("old", at: date(31, month: 8)))
        _ = try h.service.store!.insert(HistoryViewModelTests.draft("next month", at: date(1, month: 10)))
        let vm = model(h)
        vm.dateRange = range
        await vm.load()
        let expected: [String] = switch range {
        case .today: ["day 11"]
        case .thisWeek: ["day 12", "day 11", "day 7"]
        case .thisMonth: ["day 14", "day 12", "day 11", "day 7", "day 6", "day 1"]
        case .allTime: ["next month", "day 14", "day 12", "day 11", "day 7", "day 6", "day 1", "old"]
        }
        #expect(vm.records.map(\.text) == expected)
    }

    @Test("app, date and raw-text search compose; Search all time preserves app and query")
    func combinedFilters() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        for (app, day) in [("Mail", 1), ("Mail", 11), ("Slack", 11)] {
            _ = try h.service.store!.insert(DictationDraft(text: "cleaned \(day)", rawText: "Quarterly numbers",
                                                         appName: app, style: nil, language: nil, duration: 1, createdAt: date(day)))
        }
        let vm = model(h)
        vm.query = "NUMBERS"
        vm.selectedApp = "Mail"
        await vm.refresh()
        #expect(vm.records.map(\.text) == ["cleaned 11"])
        #expect(vm.availableApps == ["Mail", "Slack"])
        vm.searchAllTime()
        #expect(vm.records.map(\.text) == ["cleaned 11", "cleaned 1"])
        #expect(vm.selectedApp == "Mail")
        #expect(vm.query == "NUMBERS")
        vm.dateRange = .today
        vm.clearSearch()
        await vm.refresh()
        #expect(vm.selectedApp == "Mail")
        #expect(vm.dateRange == .today)
        #expect(vm.records.map(\.text) == ["cleaned 11"])
    }

    @Test("app options include older records beyond the former 500-row limit and unknown apps")
    func allStoredApps() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(501)
        _ = try h.service.store!.insert(HistoryViewModelTests.draft("older", appName: "Mail", at: Date(timeIntervalSince1970: -1)))
        _ = try h.service.store!.insert(DictationDraft(text: "unknown", rawText: "unknown", appName: nil,
                                                     style: nil, language: nil, duration: 1, createdAt: date(11)))
        let vm = model(h)
        await vm.load()
        #expect(vm.availableApps == ["Mail", "Slack", "Unknown app"])
        vm.selectedApp = "Mail"
        #expect(vm.emptyState == .noResults(""))
        vm.searchAllTime()
        #expect(vm.records.map(\.text) == ["older"])
        vm.selectedApp = "Unknown app"
        #expect(vm.records.map(\.text) == ["unknown"])
    }

    @Test("undo after changing filters restores storage without inserting a nonmatching visible row")
    func undoRespectsFilters() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        let mail = try h.service.store!.insert(HistoryViewModelTests.draft("mail", appName: "Mail", at: date(11)))
        _ = try h.service.store!.insert(HistoryViewModelTests.draft("slack", at: date(11)))
        let vm = model(h)
        await vm.load()
        vm.delete(mail)
        for _ in 0..<2_000 where (try? h.service.store!.count()) != 1 { await Task.yield() }
        vm.selectedApp = "Slack"
        vm.undo()
        for _ in 0..<2_000 where (try? h.service.store!.count()) != 2 { await Task.yield() }
        for _ in 0..<2_000 where !vm.availableApps.contains("Mail") { await Task.yield() }
        #expect(await h.service.count() == 2)
        #expect(vm.availableApps.contains("Mail"))
        #expect(vm.records.map(\.text) == ["slack"])
    }

    @Test("undo preserves the row position when timestamps are equal")
    func undoPreservesTiedPosition() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        for text in ["first", "middle", "last"] {
            _ = try h.service.store!.insert(HistoryViewModelTests.draft(text, at: date(11)))
        }
        let vm = model(h)
        await vm.load()
        let original = vm.records.map(\.text)
        vm.delete(vm.records[1])
        for _ in 0..<2_000 where (try? h.service.store!.count()) != 2 { await Task.yield() }
        vm.undo()
        for _ in 0..<2_000 where vm.records.count != 3 { await Task.yield() }
        #expect(vm.records.map(\.text) == original)
    }

    @Test("immediate Undo waits for a gated deletion and cannot cache both record IDs")
    func immediateUndo() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(1)
        let gate = FakeClock()
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), deleteRecord: { id in
            try? await gate.sleep(for: 1)
            await h.service.delete(id: id)
        })
        vm.dateRange = .allTime
        await vm.load()
        vm.delete(vm.records[0])
        await gate.waitForSleepers(1)
        vm.undo()
        for _ in 0..<2_000 where (try? h.service.store!.count()) == 1 { await Task.yield() }
        #expect(await h.service.count() == 1) // Reinsertion must not overtake the pending delete.
        await gate.advance(by: 1)
        for _ in 0..<2_000 where vm.records.isEmpty { await Task.yield() }
        #expect(vm.records.count == 1)
        #expect(await h.service.count() == 1)
    }

    @Test("deleting while a query is in flight restarts the interrupted search")
    func deleteDuringSearch() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        for text in ["apple", "banana"] {
            _ = try h.service.store!.insert(HistoryViewModelTests.draft(text, at: date(11)))
        }
        let gate = FakeClock()
        var heldFirstSearch = false
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), searchRecords: { query in
            let result = await h.service.search(query)
            if query == "apple", !heldFirstSearch {
                heldFirstSearch = true
                try? await gate.sleep(for: 1)
            }
            return result
        })
        vm.dateRange = .allTime
        await vm.load()
        vm.query = "apple"
        await h.clock.waitForSleepers(1)
        await h.clock.advance(by: HistoryViewModel.debounceInterval)
        await gate.waitForSleepers(1)
        vm.delete(try #require(vm.records.first { $0.text == "apple" }))
        await gate.advance(by: 1)
        for _ in 0..<2_000 where !vm.records.isEmpty { await Task.yield() }
        #expect(vm.query == "apple")
        #expect(vm.records.isEmpty)
        #expect(vm.emptyState == .noResults("apple"))
    }

    @Test("a second deletion restarts an interrupted Undo refresh even when the query is unchanged")
    func deleteDuringUndoRefresh() async throws {
        let h = HistoryViewModelTests.Harness()
        await h.seed(0)
        for text in ["apple", "banana"] {
            _ = try h.service.store!.insert(HistoryViewModelTests.draft(text, at: date(11)))
        }
        let gate = FakeClock()
        var holdRestoredApple = false
        let vm = HistoryViewModel(service: h.service, settings: h.settings, navigation: h.navigation,
                                  clock: h.clock, pasteboard: FakePasteboard(), searchRecords: { query in
            let result = await h.service.search(query)
            if holdRestoredApple, result.contains(where: { $0.text == "apple" }) {
                holdRestoredApple = false
                try? await gate.sleep(for: 1)
            }
            return result
        })
        vm.dateRange = .allTime
        await vm.load()
        vm.delete(try #require(vm.records.first { $0.text == "apple" }))
        await vm.refresh()
        holdRestoredApple = true
        vm.undo()
        await gate.waitForSleepers(1)
        vm.delete(try #require(vm.records.first { $0.text == "banana" }))
        await gate.advance(by: 1)
        for _ in 0..<2_000 where vm.records.isEmpty { await Task.yield() }
        #expect(vm.records.map(\.text) == ["apple"])
        #expect(await h.service.count() == 1)
    }
}
