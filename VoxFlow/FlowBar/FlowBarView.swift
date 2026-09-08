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

    init(content: FlowBarContent, levels: [Float],
         onOpenSettings: @escaping () -> Void = {}, onCopyRaw: @escaping () -> Void = {}) {
        self.source = .fixed(content, levels: levels)
        self.onOpenSettings = onOpenSettings
        self.onCopyRaw = onCopyRaw
    }

    /// Production entry point — copy comes from `coordinator.state`/`elapsed`/`hotkeyMode`, re-read
    /// on every render.
    init(coordinator: DictationCoordinator) {
        self.source = .coordinator(coordinator)
        self.onOpenSettings = { coordinator.openSettingsForCurrentError() }
        self.onCopyRaw = { coordinator.copyRaw() }
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
        innerContent
            .animation(.easeInOut(duration: 0.12), value: content)
            .padding(.horizontal, 14)
            .frame(height: 40)
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
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(content.timerIsAmber ? Palette.amber : Palette.hudSecondary)
            }
            if case .languageChip = content.trailing {
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.onDevice)
        case .cross:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.4))
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
        } else if !content.title.isEmpty {
            HStack(spacing: 6) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.hudText)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.hudSecondary)
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
                // along the trailing keycap instead (FB-02b).
                if content.title.isEmpty, let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.hudSecondary)
                }
            }
        case .languageChip(let text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.hudSecondary)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Palette.accent(.blue)))
            }
            .buttonStyle(.plain)
        case .copyRaw:
            pillButton("Copy raw", action: onCopyRaw)
        case .tryAgain:
            // fn is the action; the pill is a hint, not a control (FB-05) — no button, no action.
            HStack(spacing: 4) {
                Text("Try again")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.hudText)
                keycap("fn")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.16)))
        }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.hudText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.hudText.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.16)))
    }
}

/// A ¾-ring that spins forever (FB-03 "Cleaning up…", FB-12 "Loading model…"). Drawn rather than
/// `ProgressView` so it also renders correctly as a static frame in `FlowBarRenderTests`.
private struct SpinnerView: View {
    @State private var degrees: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Palette.hudSecondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(degrees))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    degrees = 360
                }
            }
    }
}
