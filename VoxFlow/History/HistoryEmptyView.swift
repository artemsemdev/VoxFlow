import SwiftUI

/// The three History empty states (design 2d "No dictations yet" / "History is off", and MW-02n
/// "no results"). One action, one line of explanation, no illustration — same pattern as design 2d's
/// other empty states.
struct HistoryEmptyView: View {
    let state: HistoryViewModel.EmptyState
    let model: HistoryViewModel

    var body: some View {
        switch state {
        case .noDictations:
            iconState(title: "No dictations yet",
                     body: "Hold fn in any text field and start talking. Everything you dictate shows up here, on this Mac only.") {
                Button("Try it in a scratchpad") { model.isScratchpadPresented = true }
                    .buttonStyle(.borderedProminent)
            }
        case .historyOff:
            iconState(title: "History is off", body: "Turn on 'Keep dictation history' in Settings → Privacy.") {
                Button("Open Privacy settings") { model.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .noResults(let query):
            noResults(query: query)
        case .unavailable(let reason):
            // I-4: no action here — unlike `.historyOff` there's no toggle that fixes a lost
            // encryption key, and unlike `.noDictations` a scratchpad capture still wouldn't save.
            iconState(title: "History is unavailable", body: "\(reason). Dictations are not being saved this session.") {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func iconState<Action: View>(title: String, body: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.1)).frame(width: 56, height: 56)
                Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noResults(query: String) -> some View {
        VStack(spacing: 12) {
            Text("No dictations match “\(query)”").font(.headline)
            Text("Search covers inserted text and the raw transcript. Try fewer words, or widen the date filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("Clear search") { model.clearSearch() }
                    .buttonStyle(.bordered)
                // Phase 4 date filters — "widen to all time" isn't wired up yet.
                Button("Search all time") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
