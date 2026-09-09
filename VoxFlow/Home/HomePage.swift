import SwiftUI

/// The Home page (design MW-01, MW-01e): thin `AppServices` wrapper around `HomePageBody`, which
/// holds the actual layout so `HomeRenderTests` can render exactly the same view instead of a
/// hand-copied approximation — same split as `HistoryPage`/`HistoryPageBody`.
struct HomePage: View {
    @Environment(AppServices.self) private var services
    private var model: HomeViewModel { services.homeViewModel }

    var body: some View {
        HomePageBody(viewModel: model)
            .navigationTitle("Home")
            // Re-runs on every navigation back to Home, same reasoning as `HistoryPage`'s `.task` —
            // numbers stay current without the caller having to remember to refresh.
            .task { await model.refresh() }
    }
}

/// `ScrollView` wrapper around `HomeContentView` — split out (not inlined) because a live
/// `ScrollView` renders entirely blank under `ImageRenderer` (confirmed empirically, same finding
/// `HistoryRenderTests` documents for History's list), so `HomeRenderTests` renders
/// `HomeContentView` directly instead.
struct HomePageBody: View {
    let viewModel: HomeViewModel

    var body: some View {
        ScrollView { HomeContentView(viewModel: viewModel) }
    }
}

/// The page content itself: greeting header + mode chip, then either the first-run pair (MW-01e:
/// Setup ~45% + "Try it here" side by side, stat cards below both — canvas page 3) or the returning
/// layout (MW-01: the Setup card full-width when ruling 3e applies, stat cards, then
/// Recent/This-week/"Everything stays on your Mac").
struct HomeContentView: View {
    let viewModel: HomeViewModel
    /// The Setup card's share of the first-run row's width (canvas page 3: Setup left ≈ 45%, "Try it
    /// here" fills the rest) — a fixed point width rather than a `GeometryReader` fraction, since the
    /// two cards' natural heights differ and a `GeometryReader` would have to be pinned to one.
    static let firstRunSetupCardWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HomeHeaderView(title: viewModel.headerTitle, subtitle: viewModel.headerSubtitle, modeChip: viewModel.modeChip)
            if viewModel.isFirstRun {
                HStack(alignment: .top, spacing: 20) {
                    SetupCard(rows: viewModel.setupRows, perform: viewModel.perform)
                        .frame(width: Self.firstRunSetupCardWidth, alignment: .top)
                    TryItCard(onAppear: viewModel.enterScratchpad, onDisappear: viewModel.leaveScratchpad)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                StatCardsRow(cards: viewModel.statCards)
            } else {
                if viewModel.showsSetupCard {
                    SetupCard(rows: viewModel.setupRows, perform: viewModel.perform)
                }
                StatCardsRow(cards: viewModel.statCards)
                HStack(alignment: .top, spacing: 20) {
                    RecentList(rows: viewModel.recentRows, seeAll: viewModel.seeAll)
                        .frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 20) {
                        WeekChart(days: viewModel.week, totalText: viewModel.weekTotalText,
                                 referenceDate: viewModel.referenceDate, calendar: .current)
                        EverythingStaysOnYourMacCard()
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding(20)
    }
}

/// Greeting + date line + the "{mode} · fn" chip (design ruling 2, header row). A standalone view
/// (not inlined in `HomeContentView`) so `HomeRenderTests`' preview can reuse it verbatim instead of
/// hand-copying it (same M3-style reasoning `HistoryRenderTests` documents).
struct HomeHeaderView: View {
    /// "Good morning, Anh" normally; "Welcome, Anh" on first run (`HomeViewModel.headerTitle`).
    let title: String
    /// The date/streak line normally; the first-run explainer (`HomeViewModel.headerSubtitle`).
    let subtitle: String
    let modeChip: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "circle").font(.caption2)
                Text(modeChip)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: Capsule())
        }
    }
}

/// The four top stat cards in a row (design ruling 1) — standalone for the same reuse reason as
/// `HomeHeaderView`.
struct StatCardsRow: View {
    let cards: [HomeStatCard]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(cards) { StatCard(model: $0) }
        }
    }
}

/// "Try it here" (design MW-01e): a scratchpad shown only while there's been no dictation yet —
/// entering/leaving `HomeViewModel`'s `EphemeralScope` on appear/disappear keeps a capture started
/// here out of real History, the same pattern History's own scratchpad sheet uses. The placeholder
/// ("Hold fn and say anything. Release to see it appear.") sits inside the box itself, like the
/// canvas — `TextEditor` has no native placeholder, so it's an overlay hidden once typing starts.
struct TryItCard: View {
    @State private var text = ""
    let onAppear: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it here").font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                if text.isEmpty {
                    Text("Hold fn and say anything. Release to see it appear.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            Text("This scratchpad isn't saved to History.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4)))
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }
}

/// "Everything stays on your Mac" (design MW-01, ruling: Speech → on-device model, Cleanup →
/// on-device LLM, History → encrypted on disk, Network → none). Pure copy, no view-model state, so
/// it isn't its own file (unlike the design's near-identical, but differently-worded, ST-05 header).
struct EverythingStaysOnYourMacCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
                Text("Everything stays on your Mac").fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Speech", "on-device model")
                row("Cleanup", "on-device LLM")
                row("History", "encrypted on disk")
                row("Network", "none")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout.weight(.medium))
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary)
        }
    }
}
