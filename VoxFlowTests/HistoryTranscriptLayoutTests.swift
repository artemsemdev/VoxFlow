import AppKit
import CryptoKit
import Observation
import SwiftUI
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct TranscriptLayoutKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: false) }
}

@Suite("History transcript native layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct HistoryTranscriptLayoutTests {
    @Test("an exploratory narrow proposal cannot change an already placed wide transcript")
    func speculativeMeasurementPreservesLiveLayout() async throws {
        let state = ProbeState()
        var host: NSHostingView<ProbeContent>?
        var window: NSWindow?
        await onRunLoop {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window?.isReleasedWhenClosed = false
            host = NSHostingView(rootView: ProbeContent(state: state))
            window?.contentView = host
            host?.layoutSubtreeIfNeeded()
        }
        for probe in [false, true] {
            state.probeNarrow = probe
            let deadline = ContinuousClock.now + .seconds(3)
            var snapshot = (CGFloat.zero, CGFloat.zero, false)
            repeat {
                snapshot = await onRunLoop {
                    host?.layoutSubtreeIfNeeded()
                    guard let host, let view = transcriptView(in: host), let container = view.textContainer,
                          let manager = view.layoutManager else { return (CGFloat.zero, CGFloat.zero, false) }
                    manager.ensureLayout(for: container)
                    return (view.bounds.width, container.containerSize.width,
                            manager.usedRect(for: container).maxY <= (view.superview?.bounds.height ?? 0) + 1)
                }
            } while (snapshot.0 != 400 || (probe && state.counter.count == 0)) && ContinuousClock.now < deadline
            if probe { #expect(state.counter.count > 0, "The real SwiftUI layout must execute the exploratory proposal") }
            #expect(snapshot.0 == 400)
            #expect(abs(snapshot.0 - snapshot.1) <= 1,
                    "Exploratory proposal enabled=\(probe): view=\(snapshot.0), container=\(snapshot.1)")
            #expect(snapshot.2, "Speculative measurement must not make glyphs overflow their allocated height")
        }
        await onRunLoop { window?.contentView = nil; host = nil; window?.close() }
    }

    @Observable @MainActor
    final class ProbeState {
        var probeNarrow = false
        let counter = ProbeCounter()
    }

    final class ProbeCounter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func record() { value.withLock { $0 += 1 } }
    }

    private struct ProbeContent: View {
        let state: ProbeState
        var body: some View {
            ProbeLayout(probeNarrow: state.probeNarrow, counter: state.counter) {
                TranscriptWordView(text: "Проверь настройки History и отправь новый invoice команде. Please review the updated numbers.",
                                   addToDictionary: { _ in })
            }
        }
    }

    /// SwiftUI may ask about another candidate width and keep the existing placement unchanged.
    private struct ProbeLayout: Layout {
        let probeNarrow: Bool
        let counter: ProbeCounter
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let accepted = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if probeNarrow {
                _ = subviews[0].sizeThatFits(ProposedViewSize(width: 100, height: nil))
                counter.record()
            }
            return accepted
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    @Test("expanded inserted text fits its actual column after wide, narrow and wide layout",
          arguments: [false, true], ["short", "long"])
    func expandedTranscriptResizes(dark: Bool, length: String) async throws {
        let directory = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.encryptHistory = false
        let service = HistoryService(directory: directory, settings: settings,
                                     keyProvider: { TranscriptLayoutKeyProvider() },
                                     clock: SystemMonotonicClock())
        _ = await service.count()
        let store = try #require(service.store)
        let transcript = length == "short"
            ? "Проверь настройки History и отправь новый invoice команде. Please review the updated numbers."
            : String(repeating: "Please send the revised invoice before Thursday so the team can review the numbers. ", count: 6)
        let first = try store.insert(DictationDraft(text: transcript, rawText: transcript,
            appName: "Mail", style: "formal", language: "en", duration: 30, createdAt: Date()))
        for index in 1...3 {
            _ = try store.insert(DictationDraft(text: "Following history row \(index)", rawText: "Following row",
                appName: "Notes", style: nil, language: "en", duration: 2,
                createdAt: Date().addingTimeInterval(Double(-index * 60))))
        }
        let model = HistoryViewModel(service: service, settings: settings, navigation: Navigation(),
                                     clock: SystemMonotonicClock(), initialDateRange: .allTime)
        await model.load()
        var window: NSWindow?
        var host: NSHostingView<AnyView>?
        await onRunLoop {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1073, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window?.isReleasedWhenClosed = false
            window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host = NSHostingView(rootView: AnyView(HistoryPageBody(viewModel: model, ephemeralScope: EphemeralScope())
                .background(Color(nsColor: .windowBackgroundColor))))
            window?.contentView = host
            host?.layoutSubtreeIfNeeded()
        }
        model.toggleExpanded(id: first.id)
        do {
            for (step, width) in [1073, 640, 1073, 900].enumerated() {
                await onRunLoop { window?.setContentSize(NSSize(width: CGFloat(width), height: 800)) }
                let deadline = ContinuousClock.now + .seconds(3)
                var snapshot: Snapshot?
                repeat {
                    snapshot = await onRunLoop {
                        host?.layoutSubtreeIfNeeded()
                        guard let host, let view = transcriptView(in: host),
                              let container = view.textContainer, let manager = view.layoutManager else { return nil }
                        manager.ensureLayout(for: container)
                        return Snapshot(windowWidth: window?.frame.width ?? 0,
                            viewWidth: view.bounds.width, containerWidth: container.containerSize.width,
                            viewHeight: view.bounds.height,
                            usedHeight: manager.usedRect(for: container).maxY + view.textContainerOrigin.y,
                            allocationHeight: view.superview?.bounds.height ?? 0,
                            allocatedTextBottom: view.frame.minY + manager.usedRect(for: container).maxY + view.textContainerOrigin.y,
                            textMatches: view.string == transcript)
                    }
                } while snapshot?.fits(width: CGFloat(width)) != true && ContinuousClock.now < deadline
                if ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil {
                    let png = await onRunLoop {
                        guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return Data?.none }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        return bitmap.representation(using: .png, properties: [:])
                    }
                    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent(".superpowers/design/renders")
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try #require(png).write(to: output.appendingPathComponent("History-layout-\(length)-\(width)-\(step)-\(dark).png"))
                }
                let actual = try #require(snapshot, "The expanded production list must host its native inserted transcript")
                #expect(actual.windowWidth == CGFloat(width))
                #expect(actual.viewWidth > 200, "The inserted column must use its available half of the card")
                #expect(abs(actual.containerWidth - actual.viewWidth) <= 1,
                        "Native text must wrap at its displayed column width: \(actual)")
                #expect(actual.usedHeight <= actual.viewHeight + 1,
                        "Every glyph must fit above the card's guidance and subsequent rows: \(actual)")
                #expect(actual.allocatedTextBottom <= actual.allocationHeight + 1,
                        "The native glyphs must remain inside SwiftUI's allocated transcript height: \(actual)")
                #expect(actual.textMatches)
            }
        } catch {
            await onRunLoop { window?.contentView = nil; host = nil; window?.close() }
            throw error
        }
        await onRunLoop { window?.contentView = nil; host = nil; window?.close() }
    }

    private struct Snapshot: Sendable {
        let windowWidth: CGFloat
        let viewWidth: CGFloat
        let containerWidth: CGFloat
        let viewHeight: CGFloat
        let usedHeight: CGFloat
        let allocationHeight: CGFloat
        let allocatedTextBottom: CGFloat
        let textMatches: Bool

        func fits(width: CGFloat) -> Bool {
            windowWidth == width && viewWidth > 200 && abs(containerWidth - viewWidth) <= 1
                && usedHeight <= viewHeight + 1 && allocatedTextBottom <= allocationHeight + 1 && textMatches
        }
    }

    private func transcriptView(in view: NSView) -> ContextWordTextView? {
        if let transcript = view as? ContextWordTextView { return transcript }
        for child in view.subviews {
            if let transcript = transcriptView(in: child) { return transcript }
        }
        return nil
    }

    private func onRunLoop<T: Sendable>(_ action: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                // RunLoop.main invokes this callback on the main thread, satisfying MainActor isolation.
                continuation.resume(returning: MainActor.assumeIsolated { action() })
            }
        }
    }
}
