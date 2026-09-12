import SwiftUI

enum OnboardingWindowID {
    static let onboarding = "onboarding"
}

/// The onboarding scene's root view: wires `@Environment(\.dismissWindow)` into the view model's
/// `dismiss` closure (`finish()` calls it) — `VoxFlowApp` owns the `Window` scene itself.
struct OnboardingWindow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingContentView(viewModel: services.onboardingViewModel)
            .onAppear {
                services.onboardingViewModel.dismiss = { dismissWindow(id: OnboardingWindowID.onboarding) }
                // MB-00: shows the menu bar hint once onboarding finishes (`OnboardingViewModel`'s
                // default `onFinished` is a no-op, so every existing direct `finish()` call in tests
                // keeps running exactly as before).
                services.onboardingViewModel.onFinished = { MenuBarServices.shared.showHintIfNeeded() }
            }
    }
}

/// The window chrome shared by every step (design ONB-01…05, 2g): step content centred, page dots
/// bottom-centre (4 dots — `.model` and `.tryIt` share the 4th), "Back" bottom-left from the
/// permissions step on, and the primary action bottom-right. The real traffic lights come from the
/// scene's own `.windowStyle(.hiddenTitleBar)` (`VoxFlowApp.swift`) — this view only reserves the
/// clearance for them (D-1: one set of chrome, not a hand-drawn pair layered under the real ones).
struct OnboardingContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: OnboardingViewModel
    let fnWarningState: FnSystemActionWarningState
    let openKeyboard: @MainActor () -> Void

    init(
        viewModel: OnboardingViewModel,
        fnWarningState: FnSystemActionWarningState = FnSystemActionWarningState(),
        openKeyboard: @escaping @MainActor () -> Void = FnSystemActionWarning.openKeyboardSettings
    ) {
        self.viewModel = viewModel
        self.fnWarningState = fnWarningState
        self.openKeyboard = openKeyboard
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)
            Spacer(minLength: 0)
            stepContent
                .padding(.horizontal, 40)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 700, height: 520)
        // Keep the light canvas while pairing dark semantic text colors with a native dark surface.
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor)
                    : Color(red: 0.965, green: 0.965, blue: 0.972))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .welcome: WelcomeStepView()
        case .permissions: PermissionsStepView(viewModel: viewModel)
        case .hotkey: HotkeyStepView(viewModel: viewModel, fnWarningState: fnWarningState, openKeyboard: openKeyboard)
        case .model: ModelStepView(viewModel: viewModel)
        case .tryIt: TryItStepView(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack {
            // M-4: canvas p.10 (ONB-05) has no Back on the final screen, unlike every other step.
            if viewModel.step != .welcome && viewModel.step != .tryIt {
                Button("Back") { viewModel.back() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            pageDots
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// 4 dots: `.model` and `.tryIt` both light the 4th — matching the design (ONB-05 shows the same
    /// 4-dot strip as ONB-04, not a 5th dot for the extra try-it screen).
    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index == min(viewModel.step.rawValue, 3) ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.step {
        case .welcome:
            Button("Get started") { viewModel.next() }
                .buttonStyle(.borderedProminent)
        case .permissions:
            if viewModel.showsAccessibilityDenied {
                // D-2: "Try again" (in the card above) stays the only blue control on ONB-02a — the
                // clipboard fallback is a secondary, not the loud action.
                Button("Continue with clipboard") { viewModel.continueWithClipboard() }
                    .buttonStyle(.bordered)
            } else {
                Button("Continue") { viewModel.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canContinue)
            }
        case .hotkey:
            Button("Continue") { viewModel.next() }
                .buttonStyle(.borderedProminent)
        case .model:
            Button("Continue") { viewModel.next() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canContinue)
        case .tryIt:
            Button("Start using VoxFlow") { viewModel.finish() }
                .buttonStyle(.borderedProminent)
        }
    }
}
