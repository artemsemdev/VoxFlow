import SwiftUI

/// The menu bar dropdown (design MB-01 "Ready"/"Listening…"/"Cleaning up…", MB-02 "Paused"/
/// "Downloading"). All copy/layout decisions come from `MenuBarViewModel` — this view only lays
/// them out, same discipline as `FlowBarView`/`GeneralSettingsBody`.
struct MenuBarView: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // M5 (Task 4 review): the canvas has no divider between the hands-free toggle and the
            // stats row directly beneath it — only between that pair and whatever comes next.
            if viewModel.isPaused {
                resumeButton
            } else if !viewModel.isCondensed {
                handsFreeRow
                statsRow
            }
            if let downloading = viewModel.downloading {
                Divider().padding(.horizontal, 14)
                downloadingRow(downloading)
            }
            Divider().padding(.horizontal, 14)
            items
            // M5: the canvas's condensed MB-02 list ("Open VoxFlow" straight into "Settings…") has no
            // divider between them — only the full MB-01 list does (History/Pause/Language above it).
            if !viewModel.isCondensed {
                Divider().padding(.horizontal, 14)
            }
            settingsAndQuit
            // M5: the canvas's condensed MB-02 dropdown has no footer line at all.
            if !viewModel.isCondensed {
                Divider().padding(.horizontal, 14)
                footer
            }
        }
        .frame(width: 280)
        .task { await viewModel.refresh() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            appIcon
            Text("VoxFlow").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(viewModel.statusColor).frame(width: 6, height: 6)
                Text(viewModel.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var appIcon: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.32, blue: 0.94), Color(red: 0.58, green: 0.4, blue: 0.95)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: ready-state rows (MB-01)

    private var handsFreeRow: some View {
        HStack {
            Text("Hands-free mode").font(.system(size: 13))
            Spacer()
            Toggle("Hands-free mode", isOn: Binding(get: { viewModel.handsFree }, set: { viewModel.handsFree = $0 }))
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            Text(viewModel.wordsTodayText).font(.system(size: 12, weight: .semibold))
            Text(viewModel.minutesSavedText).font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: paused-state row (MB-02)

    private var resumeButton: some View {
        Button(action: { viewModel.resume() }) {
            Text("Resume dictation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accent(.blue)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: downloading row (MB-02)

    private func downloadingRow(_ downloading: (name: String, percent: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading \(downloading.name)").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ProgressView(value: Double(downloading.percent), total: 100).progressViewStyle(.linear)
                Text("\(downloading.percent)%").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: item rows

    /// Full item list while ready; a shorter one (only "Open VoxFlow") while paused or downloading
    /// — matches the design's MB-02 dropdown, which drops hands-free/stats/History/pause/language.
    private var items: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Open VoxFlow", shortcut: "⌘O") { viewModel.openMain() }
            if !viewModel.isCondensed {
                menuRow("History", shortcut: "⌥⌘H") { viewModel.openHistory() }
                menuRow("Pause dictation for 1 hour") { viewModel.pauseOneHour() }
                languageRow
            }
        }
    }

    /// "Language: Auto-detect ›" (design MB-01) — a real `Menu` for the submenu behaviour, with an
    /// explicit trailing chevron: `Menu`'s own disclosure glyph is one of the AppKit-drawn controls
    /// `ImageRenderer` can't capture (see `MenuBarRenderTests`), so the design's "›" wouldn't show up
    /// in the render comparison — or reliably in a `.window`-style `MenuBarExtra` — without it.
    private var languageRow: some View {
        Menu {
            ForEach(MenuBarViewModel.languages, id: \.label) { language in
                Button(language.label) { viewModel.setLanguage(language.code) }
            }
        } label: {
            HStack {
                Text("Language: \(viewModel.languageName)").font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var settingsAndQuit: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Settings…", shortcut: "⌘,") { viewModel.openSettings() }
            menuRow("Quit VoxFlow", shortcut: "⌘Q") { viewModel.quit() }
        }
    }

    private var footer: some View {
        Text(viewModel.footer)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func menuRow(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
