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
            } while (panel.suppressReflow || abs(idealWidth - listeningWidth) > 2 || frameWidth < idealWidth - 1) && ContinuousClock.now < deadline
            // Attached and unattached hosts can differ slightly in font/pixel rounding.
            #expect(abs(idealWidth - listeningWidth) <= 2, "The live view must settle on its listening content")
            print("Flow Bar cycle \(cycle): armed=\(armedWidth), listening ideal=\(idealWidth), frame=\(frameWidth)")
            #expect(frameWidth >= idealWidth - 1, "The reused panel must fit its current listening content")
            await onRunLoop { panel.hide() }
            coordinator.escape()
            await harness.wait(coordinator) { if case .discarded = $0 { true } else { false } }
            coordinator.anyKey()
            await harness.wait(coordinator) { $0 == .idle }
        }
        await onRunLoop { panel.close() }
    }

    @Test("a continuously visible panel fits timer ticks and completed-capture restarts")
    func visibleRestarts() async throws {
        let harness = DictationCoordinatorTests()
        let (coordinator, microphone, clock, _, _) = harness.make()
        var createdPanel: FlowBarPanel?
        await onRunLoop { createdPanel = FlowBarPanel(rootView: FlowBarView(coordinator: coordinator)) }
        let panel = try #require(createdPanel)
        let scheduler = FlowBarPresenterTests.FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler)
        presenter.bind(to: coordinator)
        for cycle in 1...3 {
            coordinator.fn(.down)
            await harness.wait(coordinator) { if case .armed(_) = $0 { true } else { false } }
            await microphone.waitUntilCapturing()
            await clock.waitForSleepers(1)
            await clock.advance(by: 0.3)
            await harness.wait(coordinator) { if case .listening(_) = $0 { true } else { false } }
            for second in 1...3 {
                microphone.emit(rms: 0.5)
                for level in 0..<14 { coordinator.reportLevel(Float(level) / 14) }
                await clock.advance(by: 1)
                let tickDeadline = ContinuousClock.now + .seconds(2)
                while coordinator.elapsed < Double(second) && ContinuousClock.now < tickDeadline { await Task.yield() }
                try #require(coordinator.elapsed >= Double(second))
                let expectedWidth = await onRunLoop {
                    let content = FlowBarContent.make(state: coordinator.state, elapsed: coordinator.elapsed,
                        mode: coordinator.hotkeyMode, now: coordinator.now(), shortcuts: coordinator.shortcuts)
                    let reference = NSHostingView(rootView: FlowBarView(content: content, levels: coordinator.levels))
                    reference.layoutSubtreeIfNeeded()
                    return reference.fittingSize.width
                }
                let deadline = ContinuousClock.now + .seconds(3)
                var frameWidth: CGFloat = 0
                var minimumWidth: CGFloat = 0
                repeat {
                    // Reading the actual frame must not force live SwiftUI layout and heal the bug.
                    (frameWidth, minimumWidth) = await onRunLoop { (panel.frame.width, panel.contentMinSize.width) }
                } while (panel.suppressReflow || frameWidth < expectedWidth - 2 || minimumWidth < expectedWidth - 2) && ContinuousClock.now < deadline
                print("Visible Flow Bar cycle \(cycle), second \(second): expected=\(expectedWidth), frame=\(frameWidth)")
                #expect(frameWidth >= expectedWidth - 2)
                #expect(minimumWidth >= expectedWidth - 2, "The window must prevent clipping its listening content")
                #expect(panel.isVisible)
            }
            coordinator.fn(.up)
            await harness.wait(coordinator) { if case .inserted = $0 { true } else { false } }
            coordinator.anyKey()
            await harness.wait(coordinator) { $0 == .idle }
            #expect(panel.isVisible) // Keep the production six-second grace; never manually hide.
        }
        scheduler.cancel()
        await onRunLoop { panel.close() }
    }

    @Test("processing sets a native minimum width that fits its full status")
    func processingMinimumWidth() async throws {
        let content = FlowBarContent.make(state: .processing(Processing(startedAt: 0,
            takingLonger: false, limitReached: false, partialText: "")), elapsed: 1, mode: .pushToTalk)
        var createdPanel: FlowBarPanel?
        let expectedWidth = await onRunLoop {
            let root = FlowBarView(content: content, levels: Array(repeating: 0, count: 14))
            let reference = NSHostingView(rootView: root)
            reference.layoutSubtreeIfNeeded()
            createdPanel = FlowBarPanel(rootView: root)
            createdPanel?.show()
            return reference.fittingSize.width
        }
        let panel = try #require(createdPanel)
        let deadline = ContinuousClock.now + .seconds(3)
        var minimumWidth: CGFloat = 0
        repeat {
            minimumWidth = await onRunLoop { panel.contentMinSize.width }
        } while (panel.suppressReflow || minimumWidth < expectedWidth - 2) && ContinuousClock.now < deadline
        #expect(minimumWidth >= expectedWidth - 2, "The native window must not permit a clipped processing status")
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
