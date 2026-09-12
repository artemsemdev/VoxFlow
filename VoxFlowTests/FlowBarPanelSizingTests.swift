import AppKit
import SwiftUI
import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("Live Flow Bar panel sizing", .timeLimit(.minutes(1)))
@MainActor
struct FlowBarPanelSizingTests {
    @Test("a reused panel grows from armed to readable listening content on every capture")
    func repeatedCaptures() async throws {
        let harness = DictationCoordinatorTests()
        let (coordinator, _, clock, _, _) = harness.make()
        var createdPanel: FlowBarPanel?
        await onRunLoop { createdPanel = FlowBarPanel(rootView: FlowBarView(coordinator: coordinator)) }
        let panel = try #require(createdPanel)
        for cycle in 1...3 {
            coordinator.fn(.down)
            await harness.wait(coordinator) { if case .armed = $0 { true } else { false } }
            let armedWidth = await onRunLoop {
                panel.show()
                return panel.frame.width
            }
            await clock.waitForSleepers(1)
            await clock.advance(by: 0.3)
            await harness.wait(coordinator) { if case .listening = $0 { true } else { false } }
            // Measure a fresh listening view using this runner's fonts and content. The panel's
            // initial frame can still reflect an older state, so its width is not a growth baseline.
            let listeningWidth = await onRunLoop {
                let content = FlowBarContent.make(state: coordinator.state, elapsed: coordinator.elapsed,
                    mode: coordinator.hotkeyMode, now: coordinator.now(), shortcuts: coordinator.shortcuts)
                let reference = NSHostingView(rootView: FlowBarView(content: content, levels: coordinator.levels))
                reference.layoutSubtreeIfNeeded()
                return reference.fittingSize.width
            }
            #expect(listeningWidth > 0)
            let deadline = ContinuousClock.now + .seconds(3)
            var idealWidth: CGFloat = 0
            var frameWidth: CGFloat = 0
            repeat {
                let widths = await onRunLoop {
                    panel.contentView?.layoutSubtreeIfNeeded()
                    return (panel.contentView?.fittingSize.width ?? 0, panel.frame.width)
                }
                (idealWidth, frameWidth) = widths
            } while (panel.suppressReflow || abs(idealWidth - listeningWidth) > 1 || frameWidth < listeningWidth - 1) && ContinuousClock.now < deadline
            #expect(abs(idealWidth - listeningWidth) <= 1, "The live view must settle on its listening content")
            print("Flow Bar cycle \(cycle): armed=\(armedWidth), listening ideal=\(idealWidth), frame=\(frameWidth)")
            #expect(frameWidth >= listeningWidth - 1, "The reused panel must fit its current listening content")
            await onRunLoop { panel.hide() }
            coordinator.escape()
            await harness.wait(coordinator) { if case .discarded = $0 { true } else { false } }
            coordinator.anyKey()
            await harness.wait(coordinator) { $0 == .idle }
        }
        await onRunLoop { panel.close() }
    }

    private func onRunLoop<T: Sendable>(_ action: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                // RunLoop.main executes this callback on the main thread, satisfying MainActor isolation.
                continuation.resume(returning: MainActor.assumeIsolated { action() })
            }
        }
    }
}
