import SwiftUI

/// The Flow Bar pill (design 1a/2a): dark HUD material, 40 pt tall, one line — leading indicator,
/// waveform/title zone, optional timer, optional trailing keycap/chip/button. All copy and zone
/// decisions come from `FlowBarContent`; this view only lays them out.
struct FlowBarView: View {
    /// Where copy/levels come from: a fixed snapshot (previews, `FlowBarRenderTests`) or the live
    /// coordinator, read fresh on every `body` evaluation so SwiftUI's `@Observable` tracking sees
    /// the access and re-renders when `coordinator.state`/`elapsed`/`levels`/`hotkeyMode` change —
    /// reading them once in `init` instead would freeze the HUD on whatever state it first saw.
    private enum Source {
        case fixed(FlowBarContent, levels: [Float])
        case coordinator(DictationCoordinator)
    }

    private let source: Source
    let onOpenSettings: () -> Void
    let onCopyRaw: () -> Void
    let onResume: () -> Void

    init(content: FlowBarContent, levels: [Float],
         onOpenSettings: @escaping () -> Void = {}, onCopyRaw: @escaping () -> Void = {}, onResume: @escaping () -> Void = {}) {
        self.source = .fixed(content, levels: levels)
        self.onOpenSettings = onOpenSettings
        self.onCopyRaw = onCopyRaw
        self.onResume = onResume
    }

    /// Production entry point — copy comes from `coordinator.state`/`elapsed`/`hotkeyMode`, re-read
    /// on every render, against the default `FlowBarConfig()` (the coordinator doesn't expose a
    /// customised one; see the Task 4 fix report).
    init(coordinator: DictationCoordinator) {
        self.source = .coordinator(coordinator)
        self.onOpenSettings = { coordinator.openSettingsForCurrentError() }
        self.onCopyRaw = { coordinator.copyRaw() }
        self.onResume = { coordinator.resume() }
    }

    private var content: FlowBarContent {
        switch source {
        case .fixed(let content, levels: _): content
        case .coordinator(let coordinator): FlowBarContent.make(state: coordinator.state, elapsed: coordinator.elapsed, mode: coordinator.hotkeyMode)
        }
    }

    private var levels: [Float] {
        switch source {
        case .fixed(_, levels: let levels): levels
        case .coordinator(let coordinator): coordinator.levels
        }
    }

    var body: some View {
        ZStack {
            // Keyed on `content.contentIdentity` (leading/title/subtitle/waveform/trailing — not
            // `timer`/`timerIsAmber`), not `content` itself: `.id()` is *identity*, and `content`
            // changes every time `DictationCoordinator.elapsed` ticks, which would otherwise remove
            // and re-insert this whole subtree — a visible cross-dissolve of the entire pill once a
            // second while listening — instead of just updating the timer text in place.
            innerContent
                .id(content.contentIdentity)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.12), value: content.contentIdentity)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: 560)
        .fixedSize()
        .background(Capsule().fill(Palette.hudBackground))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
        .animation(.easeOut(duration: 0.2), value: content)
    }

    private var innerContent: some View {
        HStack(spacing: 10) {
            leading
            middle
            if let timer = content.timer {
                Text(timer)
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(content.timerIsAmber ? Palette.amber : Palette.hudText)
                    .fixedSize()
            }
            // FB-02 *and* FB-02b both show the divider before the trailing zone (chip or "fn"
            // keycap) — not just before the language chip.
            if content.timer != nil && content.trailing != nil {
                Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 14)
            }
            trailing
        }
    }

    @ViewBuilder private var leading: some View {
        switch content.leading {
        case .dot(let color):
            Circle().fill(dotColor(color)).frame(width: 8, height: 8)
        case .spinner:
            // A hand-drawn arc rather than `ProgressView`: `ImageRenderer` freezes an indeterminate
            // `ProgressView` on an odd fallback glyph instead of a ring, which broke the design
            // renders (FB-03/FB-12) — this draws correctly both live and as a static snapshot.
            SpinnerView()
        case .check:
            // Not `checkmark.circle.fill`: its tick is a knockout (dark-on-green), the canvas shows
            // a filled disc with a *white* tick — draw the disc and overlay the glyph instead.
            ZStack {
                Circle().fill(Palette.onDevice)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 15, height: 15)
        case .cross:
            // Same knockout problem as `.check` — a grey disc with a white ✕ on top.
            ZStack {
                Circle().fill(Color.white.opacity(0.32))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 15, height: 15)
        case .excluded:
            Image(systemName: "rectangle.slash")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func dotColor(_ color: FlowBarContent.DotColor) -> Color {
        switch color {
        case .idle: Color.white.opacity(0.35)
        case .recording: Palette.recording
        case .warning: Palette.amber
        case .error: Palette.recording
        }
    }

    @ViewBuilder private var middle: some View {
        if content.showsWaveform {
            WaveformView(levels: levels)
        } else if content.showsTitleZone {
            HStack(spacing: 6) {
                // No `.fixedSize()` here, unlike every other label in the pill: `title` can carry an
                // arbitrary app/error name ("Inserted into <app>", "Dictation is off in <app>",
                // "Microphone in use by <app>", `.error`'s message) with no length the model can
                // bound. `.lineLimit(1)` + a capped width truncates instead of growing the pill (and
                // the outer `.frame(maxWidth: 560)`) without limit — see `FlowBarRenderTests`'
                // "excluded-long-app-name" case.
                Text(content.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.hudText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400, alignment: .leading)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.hudSecondary)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch content.trailing {
        case .keycap(let text):
            HStack(spacing: 6) {
                keycap(text)
                // "fn stop": the hands-free hint has no title zone, so its "stop" subtitle rides
                // along the trailing keycap instead (FB-02b) — `FlowBarContent.subtitleBesideTrailing`
                // is the (model-owned) placement decision, not something re-derived here.
                if content.subtitleBesideTrailing, let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.hudSecondary)
                        .fixedSize()
                }
            }
        case .languageChip(let text):
            HStack(spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.hudText)
                    .fixedSize()
                // An SF Symbol rather than a raw "▾" glyph: the bare Unicode triangle fell back to
                // a font with wildly different metrics, which starved the sibling `Text(text)` of
                // width and truncated "EN?" down to an ellipsis in `FlowBarRenderTests`' renders.
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Palette.hudText.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        case .button(let button):
            trailingButton(button)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func trailingButton(_ button: FlowBarContent.Button) -> some View {
        switch button {
        case .openSettings:
            pillButton("Open Settings", action: onOpenSettings)
        case .download(let sizeText):
            Button(action: onOpenSettings) {
                Text("Download \(sizeText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.accent(.blue)))
            }
            .buttonStyle(.plain)
        case .copyRaw:
            pillButton("Copy raw", action: onCopyRaw)
        case .resume:
            pillButton("Resume", action: onResume)
        case .tryAgain:
            // fn is the action; the pill is a hint, not a control (FB-05) — no button, no action.
            // The canvas renders the trailing "fn" as plain dimmed text here, not a boxed keycap.
            HStack(spacing: 4) {
                Text("Try again")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.hudText)
                    .fixedSize()
                Text("fn")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.hudSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.hudText)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    // `KeycapView(style: .dark)` — extracted to `VoxFlow/Design/KeycapView.swift` so Settings ›
    // Hotkeys (ST-02) can reuse the same shape.
    private func keycap(_ text: String) -> some View { KeycapView(text: text, style: .dark) }
}

/// A near-full ring that spins forever (FB-03 "Cleaning up…", FB-12 "Loading model…"). Drawn rather
/// than `ProgressView` so it also renders correctly as a static frame in `FlowBarRenderTests`.
private struct SpinnerView: View {
    @State private var degrees: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.85)
            .stroke(Palette.hudText.opacity(0.9), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(degrees))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    degrees = 360
                }
            }
    }
}
