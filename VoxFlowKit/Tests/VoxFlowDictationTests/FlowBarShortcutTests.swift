import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("Flow Bar dedicated shortcuts")
struct FlowBarShortcutTests {
    let ok = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded)

    @Test("a dedicated push-to-talk shortcut captures immediately and even a short release finishes")
    func pushToTalk() {
        var machine = FlowBarMachine()
        #expect(machine.handle(.shortcutDown(.pushToTalk, ok), now: 10) == [.startCapture, .startTimer(.cap, seconds: 900)])
        #expect(machine.state == .listening(Listening(mode: .pushToTalk, startedAt: 10, language: nil)))
        let effects = machine.handle(.pushToTalkReleased, now: 10.1)
        #expect(machine.state.isProcessing)
        #expect(effects.contains(.finishCapture))
        #expect(!effects.contains(.startTimer(.doubleTap, seconds: 0.35)))
    }

    @Test("hands-free starts on one press, ignores push-to-talk release, and stops on its next press")
    func handsFree() {
        var machine = FlowBarMachine()
        #expect(machine.handle(.shortcutDown(.handsFree, ok), now: 10) ==
                [.startCapture, .startTimer(.cap, seconds: 900), .startTimer(.silence, seconds: 3)])
        #expect(machine.state == .listening(Listening(mode: .handsFree, startedAt: 10, language: nil)))
        #expect(machine.handle(.pushToTalkReleased, now: 11).isEmpty)
        #expect(machine.handle(.shortcutDown(.handsFree, ok), now: 12).contains(.finishCapture))
        #expect(machine.state.isProcessing)
    }

    @Test("pressing the other mode's shortcut never switches or finishes an active capture")
    func independentModes() {
        for (active, other): (HotkeyMode, HotkeyMode) in [(.pushToTalk, .handsFree), (.handsFree, .pushToTalk)] {
            var machine = FlowBarMachine()
            _ = machine.handle(.shortcutDown(active, ok), now: 0)
            let before = machine.state
            #expect(machine.handle(.shortcutDown(other, ok), now: 1).isEmpty)
            #expect(machine.state == before)
        }
    }

    @Test("releasing push-to-talk or stopping hands-free during model loading finishes once ready")
    func stopDuringLoading() {
        var loading = ok
        loading.model = .installedNotLoaded
        for mode: HotkeyMode in [.pushToTalk, .handsFree] {
            var machine = FlowBarMachine()
            #expect(machine.handle(.shortcutDown(mode, loading), now: 0) ==
                    [.startCapture, .loadModel, .startTimer(.modelLoad, seconds: 30)])
            let stop: FlowBarEvent = mode == .pushToTalk ? .pushToTalkReleased : .shortcutDown(.handsFree, loading)
            #expect(machine.handle(stop, now: 0.1).isEmpty)
            #expect(machine.handle(.modelLoaded, now: 1).contains(.finishCapture))
            #expect(machine.state.isProcessing)
            #expect(machine.handle(.modelLoaded, now: 1.1).isEmpty)
        }
    }

    @Test("a ready model enters the selected mode without a hold timer or a second capture")
    func modelBecomesReady() {
        var loading = ok
        loading.model = .installedNotLoaded
        for mode: HotkeyMode in [.pushToTalk, .handsFree] {
            var machine = FlowBarMachine()
            _ = machine.handle(.shortcutDown(mode, loading), now: 0)
            let effects = machine.handle(.modelLoaded, now: 1)
            #expect(machine.state == .listening(Listening(mode: mode, startedAt: 0, language: nil)))
            #expect(!effects.contains(.startCapture))
            #expect(effects.contains(.cancelTimer(.modelLoad)))
        }
    }

    @Test("dedicated shortcuts use the same preflight gates as fn")
    func preflight() {
        var withoutPreflight = FlowBarMachine()
        #expect(withoutPreflight.handle(.shortcutDown(.handsFree, nil), now: 0).isEmpty)
        #expect(withoutPreflight.state == .idle)
        let denied = [
            Preflight(excludedApp: "Private", secureInput: false, microphone: .granted, model: .loaded),
            Preflight(excludedApp: nil, secureInput: true, microphone: .granted, model: .loaded),
            Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded),
            Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 42))
        ]
        for gate in denied {
            var reference = FlowBarMachine()
            let effects = reference.handle(.fnDown(gate), now: 0)
            for mode: HotkeyMode in [.pushToTalk, .handsFree] {
                var machine = FlowBarMachine()
                #expect(machine.handle(.shortcutDown(mode, gate), now: 0) == effects)
                #expect(machine.state == reference.state)
            }
        }
    }

    @Test("a failed legacy gesture's hold timer cannot turn a dedicated hands-free retry into push-to-talk")
    func staleHoldAfterRetry() {
        var loading = ok
        loading.model = .installedNotLoaded
        var machine = FlowBarMachine()
        _ = machine.handle(.fnDown(loading), now: 0)
        _ = machine.handle(.microphoneFailed(.accessDenied), now: 0.1)
        _ = machine.handle(.shortcutDown(.handsFree, loading), now: 0.2)
        let before = machine.state
        #expect(machine.handle(.timer(.hold), now: 0.25).isEmpty)
        #expect(machine.state == before)
        _ = machine.handle(.modelLoaded, now: 1)
        #expect(machine.state == .listening(Listening(mode: .handsFree, startedAt: 0.2, language: nil)))
        #expect(machine.handle(.shortcutDown(.handsFree, nil), now: 2).contains(.finishCapture))
    }

    @Test("paused and processing states ignore shortcut starts; dismissable states permit retry")
    func busyAndRetry() {
        for mode: HotkeyMode in [.pushToTalk, .handsFree] {
            for state: FlowBarState in [.paused(until: 100), .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: ""))] {
                var machine = FlowBarMachine()
                machine.state = state
                #expect(machine.handle(.shortcutDown(mode, ok), now: 1).isEmpty)
                #expect(machine.state == state)
            }
            var machine = FlowBarMachine()
            machine.state = .discarded
            let effects = machine.handle(.shortcutDown(mode, ok), now: 2)
            #expect(effects.first == .cancelTimer(.dismiss))
            #expect(effects.contains(.startCapture))
        }
    }
}
