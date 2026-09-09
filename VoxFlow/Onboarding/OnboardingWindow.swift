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
            }
    }
}

/// The window chrome shared by every step (design ONB-01…05, 2g): traffic lights top-left, step
/// content centred, page dots bottom-centre (4 dots — `.model` and `.tryIt` share the 4th), "Back"
/// bottom-left from the permissions step on, and the primary action bottom-right.
struct OnboardingContentView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            trafficLights
            Spacer(minLength: 0)
            stepContent
                .padding(.horizontal, 40)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 700, height: 520)
        .background(Color(red: 0.965, green: 0.965, blue: 0.972))
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
            Circle().fill(Color.black.opacity(0.12)).frame(width: 12, height: 12)
            Circle().fill(Color.black.opacity(0.12)).frame(width: 12, height: 12)
            Spacer()
        }
        .padding(.leading, 20)
        .padding(.top, 20)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .welcome: WelcomeStepView()
        case .permissions: PermissionsStepView(viewModel: viewModel)
        case .hotkey: HotkeyStepView(viewModel: viewModel)
        case .model: ModelStepView(viewModel: viewModel)
        case .tryIt: TryItStepView(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.step != .welcome {
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
                    .fill(index == min(viewModel.step.rawValue, 3) ? Color.accentColor : Color.black.opacity(0.15))
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
                Button("Continue with clipboard") { viewModel.continueWithClipboard() }
                    .buttonStyle(.borderedProminent)
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
