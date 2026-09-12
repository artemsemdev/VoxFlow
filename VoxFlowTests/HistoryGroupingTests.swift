import Foundation
import SwiftUI
import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("History calendar groups") @MainActor
struct HistoryGroupingTests {
    private final class MutableDate {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private func makeModel(_ harness: HistoryViewModelTests.Harness, now: MutableDate) -> HistoryViewModel {
        HistoryViewModel(service: harness.service, settings: harness.settings, navigation: harness.navigation,
                         clock: harness.clock, pasteboard: FakePasteboard(), calendar: calendar,
                         now: { now.value }, initialDateRange: .allTime)
    }

    @Test("known apps use the canvas tile palette")
    func knownAppColors() {
        #expect(HistoryViewModel.color(for: "Mail") == Color(red: 10 / 255, green: 132 / 255, blue: 1))
        #expect(HistoryViewModel.color(for: "Slack") == Color(red: 97 / 255, green: 31 / 255, blue: 105 / 255))
        #expect(HistoryViewModel.color(for: "Notes") == Color(red: 242 / 255, green: 178 / 255, blue: 27 / 255))
        #expect(HistoryViewModel.color(for: "Xcode") == Color(red: 30 / 255, green: 139 / 255, blue: 1))
        #expect(HistoryViewModel.color(for: "Arc") == .green)
        #expect(HistoryViewModel.color(for: nil) == .gray)
    }

    @Test("older years remain explicit")
    func olderYearHeading() async throws {
        let harness = HistoryViewModelTests.Harness()
        await harness.seed(0)
        let old = calendar.date(from: DateComponents(year: 2025, month: 9, day: 11))!
        _ = try harness.service.store!.insert(HistoryViewModelTests.draft("last year", at: old))
        let model = makeModel(harness, now: MutableDate(date(11)))
        await model.load()
        #expect(model.dayGroups().map(\.title) == ["September 11, 2025"])
    }

    @Test("visible rows group by local day with readable headings")
    func localDayGroups() async throws {
        let harness = HistoryViewModelTests.Harness()
        await harness.seed(0)
        for (text, day, hour) in [("today late", 11, 16), ("today early", 11, 9),
                                  ("yesterday", 10, 20), ("older", 7, 8)] {
            _ = try harness.service.store!.insert(HistoryViewModelTests.draft(text, at: date(day, hour: hour)))
        }
        let model = makeModel(harness, now: MutableDate(date(11, hour: 18)))
        await model.load()

        let groups = model.dayGroups()
        #expect(groups.map(\.title) == ["Today", "Yesterday", "September 7"])
        #expect(groups.map { $0.records.map(\.text) }
            == [["today late", "today early"], ["yesterday"], ["older"]])
    }

    @Test("midnight reapplies Today while an active edit stays pinned in its original day")
    func midnightAndEditPinning() async throws {
        let harness = HistoryViewModelTests.Harness()
        await harness.seed(0)
        let yesterday = try harness.service.store!.insert(
            HistoryViewModelTests.draft("editing", at: date(11, hour: 23)))
        _ = try harness.service.store!.insert(HistoryViewModelTests.draft("new day", at: date(12, hour: 1)))
        let now = MutableDate(date(11, hour: 23))
        let model = makeModel(harness, now: now)
        model.dateRange = .today
        await model.load()
        model.beginEditing(yesterday)

        now.value = date(12, hour: 2)
        model.dateBoundaryDidChange()

        #expect(model.records.map(\.text) == ["editing", "new day"])
        #expect(model.dayGroups().map(\.title) == ["Yesterday", "Today"])
        #expect(model.dayGroups().flatMap(\.records).filter { $0.id == yesterday.id }.count == 1)
    }
}
