import SwiftUI
import VoxFlowDictation

/// ONB-01 "Speak. It types." — icon, title, body, three on-device chips.
struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 22) {
            appIcon
            VStack(spacing: 10) {
                Text("Speak. It types.")
                    .font(.system(size: 34, weight: .bold))
                Text("VoxFlow turns your voice into clean text in any app — entirely on this Mac. Nothing you say ever leaves it.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 20) {
                chip("On-device models")
                chip("Works offline")
                chip("No account")
            }
        }
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.58, blue: 1), Color(red: 0.02, green: 0.32, blue: 0.96)],
                                     startPoint: .top, endPoint: .bottom))
            HStack(spacing: 6) {
                waveBar(height: 20)
                waveBar(height: 38)
                waveBar(height: 20)
            }
        }
        .frame(width: 88, height: 88)
    }

    private func waveBar(height: CGFloat) -> some View {
        Capsule().fill(Color.white).frame(width: 7, height: height)
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.onDevice).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// ONB-02 "Two permissions, both local" and its ONB-02a Accessibility-denied branch.
struct PermissionsStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Two permissions, both local").font(.system(size: 24, weight: .bold))
                Text("macOS asks for these; VoxFlow uses them only on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                microphoneRow
                Divider().padding(.leading, 60)
                accessibilityRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.06)))

            if viewModel.showsAccessibilityDenied {
                whyThisPermission
            }
        }
        .frame(maxWidth: 480)
    }

    private var microphoneRow: some View {
        HStack(spacing: 14) {
            rowIcon("mic.fill", color: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").font(.system(size: 13, weight: .semibold))
                Text("To hear you. Audio never leaves memory.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if viewModel.microphone == .granted {
                grantedLabel
            } else {
                Button("Allow…") { Task { await viewModel.requestMicrophone() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var accessibilityRow: some View {
        HStack(spacing: 14) {
            rowIcon("keyboard", color: viewModel.showsAccessibilityDenied ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.showsAccessibilityDenied ? "Accessibility — not granted" : "Accessibility")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(viewModel.showsAccessibilityDenied ? .orange : .primary)
                if viewModel.showsAccessibilityDenied {
                    Text("Without it VoxFlow can't type for you. It will copy text to the clipboard instead.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("To type into whichever app you're using.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("System Settings → Privacy & Security → Accessibility → enable VoxFlow.")
                        .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if viewModel.accessibilityGranted {
                grantedLabel
            } else if viewModel.showsAccessibilityDenied {
                Button("Try again") { viewModel.tryAgainAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Open System Settings…") { viewModel.openAccessibilitySettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(viewModel.showsAccessibilityDenied ? Color.orange.opacity(0.14) : Color.clear)
    }

    private var whyThisPermission: some View {
        (Text("Why this permission?  ").fontWeight(.semibold)
         + Text("Accessibility is how macOS lets an app insert text into another app's field. VoxFlow reads nothing from your screen — only writes what you dictated."))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var grantedLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.onDevice).frame(width: 6, height: 6)
            Text("Granted").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.onDevice)
        }
    }

    private func rowIcon(_ systemName: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay(Image(systemName: systemName).font(.system(size: 14)).foregroundStyle(color))
    }
}

/// ONB-03 "How do you want to start?" — two selectable hotkey-mode cards.
struct HotkeyStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("How do you want to start?").font(.system(size: 24, weight: .bold))
                Text("Both use the fn key. You can change this anytime.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                modeCard(mode: .pushToTalk, title: "Push-to-talk", keycaps: ["fn"],
                        body: "Hold fn while you speak. Release and the text is inserted. Precise, nothing runs on its own.")
                modeCard(mode: .handsFree, title: "Hands-free", keycaps: ["fn", "fn"],
                        body: "Double-tap fn to start, tap once to stop. Best for longer thoughts. Stops after 3 s of silence.")
            }
        }
        .frame(maxWidth: 560)
    }

    private func modeCard(mode: HotkeyMode, title: String, keycaps: [String], body: String) -> some View {
        let selected = viewModel.hotkeyMode == mode
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in keycap(cap) }
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { viewModel.choose(mode) }
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.15), lineWidth: 1))
            )
    }
}

/// ONB-05 "You're set. Try it." — scratchpad, result chip, and the closing "never left this Mac" line.
struct TryItStepView: View {
    let viewModel: OnboardingViewModel
    @State private var scratchpad = ""

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Palette.onDevice).frame(width: 56, height: 56)
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("You're set. Try it.").font(.system(size: 24, weight: .bold))
                (Text("Hold ").foregroundStyle(.secondary)
                 + Text("fn").fontWeight(.semibold)
                 + Text(", say a sentence, let go.").foregroundStyle(.secondary))
                    .font(.system(size: 13))
            }
            TextEditor(text: $scratchpad)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 64)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5))
                .frame(maxWidth: 420)

            if let result = viewModel.tryItResult {
                Text(result)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.hudBackground))
            }

            Text("That never left this Mac. Neither will anything else.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
