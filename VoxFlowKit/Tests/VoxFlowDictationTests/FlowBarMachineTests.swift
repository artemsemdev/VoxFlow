import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("FlowBarMachine")
struct FlowBarMachineTests {
    let ok = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded)
    let config = FlowBarConfig()

    @Test("fn-down starts capture and the hold timer; holding 250 ms → push-to-talk listening")
    func pushToTalk() {
        var m = FlowBarMachine()
        var effects = m.handle(.fnDown(ok), now: 10)
        #expect(effects == [.startCapture, .startTimer(.hold, seconds: 0.25)])
        #expect(m.state == .armed(Pending(downAt: 10, fnIsDown: true, resolvedMode: nil)))
        effects = m.handle(.timer(.hold), now: 10.25)
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 10, language: nil)))
        #expect(effects == [.startTimer(.cap, seconds: 900)])
        effects = m.handle(.fnUp, now: 12)
        #expect(m.state == .processing(Processing(startedAt: 12, takingLonger: false, limitReached: false, partialText: "")))
        #expect(effects == [.cancelTimer(.cap), .cancelTimer(.silence), .finishCapture,
                            .startTimer(.takingLonger, seconds: 8), .startTimer(.processingTimeout, seconds: 20)])
    }

    @Test("two taps within 350 ms → hands-free; a single tap discards silently")
    func handsFree() {
        var m = FlowBarMachine()
        _ = m.handle(.fnDown(ok), now: 0)
        var effects = m.handle(.fnUp, now: 0.1)
        #expect(m.state == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))
        #expect(effects == [.cancelTimer(.hold), .startTimer(.doubleTap, seconds: 0.35)])
        effects = m.handle(.fnDown(ok), now: 0.3)
        #expect(m.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        #expect(effects == [.cancelTimer(.doubleTap), .startTimer(.cap, seconds: 900), .startTimer(.silence, seconds: 3)])
        #expect(m.handle(.fnUp, now: 0.4).isEmpty)   // the release of the second tap is ignored

        var single = FlowBarMachine()
        _ = single.handle(.fnDown(ok), now: 0)
        _ = single.handle(.fnUp, now: 0.1)
        #expect(single.handle(.timer(.doubleTap), now: 0.45) == [.abortCapture])
        #expect(single.state == .idle)
    }

    @Test("hands-free: voice restarts the silence timer, silence stops, a tap stops, cap stops with limitReached")
    func handsFreeStops() {
        var m = FlowBarMachine.listening(.handsFree, at: 0)
        #expect(m.handle(.level(rms: 0.2), now: 1) == [.startTimer(.silence, seconds: 3)])
        #expect(m.handle(.level(rms: 0.001), now: 2).isEmpty)
        _ = m.handle(.timer(.silence), now: 5)
        #expect(m.state.isProcessing)

        var tap = FlowBarMachine.listening(.handsFree, at: 0)
        _ = tap.handle(.fnDown(ok), now: 4)
        #expect(tap.state.isProcessing)

        var cap = FlowBarMachine.listening(.pushToTalk, at: 0)
        _ = cap.handle(.timer(.cap), now: 900)
        guard case .processing(let p) = cap.state else { Issue.record("expected processing"); return }
        #expect(p.limitReached)
    }

    @Test("push-to-talk ignores silence; custom silence stop is clamped to 1…10 s")
    func silenceRules() {
        var m = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(m.handle(.level(rms: 0.5), now: 1).isEmpty)
        #expect(FlowBarConfig(silenceStop: 0.2).silenceStop == 1)
        #expect(FlowBarConfig(silenceStop: 42).silenceStop == 10)
    }

    @Test("transcript → insert → inserted with words and 1.5 s dismiss; clipboard fallback → copied 2.5 s")
    func insertion() {
        var m = FlowBarMachine.processing(at: 0)
        var effects = m.handle(.transcriptReady(text: "hello there world", lowConfidence: false), now: 1)
        #expect(effects == [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .insert("hello there world")])
        effects = m.handle(.insertionFinished(.inserted(appName: "Mail")), now: 1.2)
        #expect(m.state == .inserted(appName: "Mail", words: 3, limitReached: false))
        #expect(effects == [.saveHistory, .startTimer(.dismiss, seconds: 1.5)])
        #expect(m.handle(.timer(.dismiss), now: 3) == [])
        #expect(m.state == .idle)

        var c = FlowBarMachine.processing(at: 0)
        _ = c.handle(.transcriptReady(text: "one two", lowConfidence: false), now: 1)
        #expect(c.handle(.insertionFinished(.copiedToClipboard), now: 1) == [.saveHistory, .startTimer(.dismiss, seconds: 2.5)])
        #expect(c.state == .copied)
    }

    @Test("empty or < 2 low-confidence words → didn't catch (4 s); a retry fn-down works from there")
    func didntCatch() {
        var m = FlowBarMachine.processing(at: 0)
        #expect(m.handle(.transcriptReady(text: "", lowConfidence: false), now: 1) ==
                [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .didntCatch(rawAvailable: false))
        #expect(m.handle(.fnDown(ok), now: 2) == [.cancelTimer(.dismiss), .startCapture, .startTimer(.hold, seconds: 0.25)])

        var low = FlowBarMachine.processing(at: 0)
        _ = low.handle(.transcriptReady(text: "um", lowConfidence: true), now: 1)
        #expect(low.state == .didntCatch(rawAvailable: false))

        var fine = FlowBarMachine.processing(at: 0)
        _ = fine.handle(.transcriptReady(text: "um", lowConfidence: false), now: 1)
        #expect(fine.state.isProcessing)   // one confident word is still inserted
    }

    @Test("8 s → Taking longer…; 20 s → didn't catch with raw available and capture aborted; copy raw")
    func slowProcessing() {
        var m = FlowBarMachine.processing(at: 0)
        _ = m.handle(.partialText("so far so"), now: 3)
        #expect(m.handle(.timer(.takingLonger), now: 8).isEmpty)
        guard case .processing(let p) = m.state else { Issue.record("expected processing"); return }
        #expect(p.takingLonger && p.partialText == "so far so")
        #expect(m.handle(.timer(.processingTimeout), now: 20) == [.abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .didntCatch(rawAvailable: true))
        #expect(m.handle(.copyRawRequested, now: 21) == [.copyToClipboard("so far so")])
    }

    @Test("esc while listening or processing → discarded 0.8 s, nothing saved")
    func escape() {
        var l = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(l.handle(.escape, now: 1) == [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        #expect(l.state == .discarded)
        var p = FlowBarMachine.processing(at: 0)
        #expect(p.handle(.escape, now: 1) == [.cancelTimer(.takingLonger), .cancelTimer(.processingTimeout), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        var i = FlowBarMachine()
        #expect(i.handle(.escape, now: 0).isEmpty)
        var armed = FlowBarMachine()
        _ = armed.handle(.fnDown(ok), now: 0)
        #expect(armed.handle(.escape, now: 0.1) == [.cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        #expect(armed.state == .discarded)
        var tapped = FlowBarMachine()
        _ = tapped.handle(.fnDown(ok), now: 0)
        _ = tapped.handle(.fnUp, now: 0.1)
        _ = tapped.handle(.escape, now: 0.2)
        #expect(tapped.state == .discarded)
    }

    @Test("preflight gates: excluded app, secure input, mic denied / no device, model missing", arguments: [
        (Preflight(excludedApp: "1Password", secureInput: false, microphone: .granted, model: .loaded), FlowBarState.excluded(app: "1Password")),
        (Preflight(excludedApp: nil, secureInput: true, microphone: .granted, model: .loaded), .excluded(app: "a secure field")),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded), .micUnavailable(.denied)),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .noDevice, model: .loaded), .micUnavailable(.noDevice)),
        (Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .notInstalled(sizeBytes: 1_624_555_275)), .modelNotInstalled(sizeBytes: 1_624_555_275)),
    ])
    func gates(preflight: Preflight, expected: FlowBarState) {
        var m = FlowBarMachine()
        #expect(m.handle(.fnDown(preflight), now: 0) == [.startTimer(.dismiss, seconds: 4)])
        #expect(m.state == expected)
        #expect(m.handle(.anyKey, now: 1) == [.cancelTimer(.dismiss)])
        #expect(m.state == .idle)
    }

    @Test("model installed but not loaded: capture + load; loaded while still holding → listening; released → armed rules")
    func loadingModel() {
        let cold = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded)
        var m = FlowBarMachine()
        #expect(m.handle(.fnDown(cold), now: 0) == [.startCapture, .loadModel, .startTimer(.modelLoad, seconds: 30), .startTimer(.hold, seconds: 0.25)])
        #expect(m.state == .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        #expect(m.handle(.timer(.hold), now: 0.25).isEmpty)
        #expect(m.state == .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: .pushToTalk)))
        #expect(m.handle(.modelLoaded, now: 1.5) == [.cancelTimer(.modelLoad), .startTimer(.cap, seconds: 900)])
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))

        var early = FlowBarMachine()
        _ = early.handle(.fnDown(cold), now: 0)
        _ = early.handle(.fnUp, now: 0.1)
        _ = early.handle(.timer(.doubleTap), now: 0.45)
        #expect(early.state == .idle)   // lone tap while loading: nothing to transcribe, model stays warm

        var released = FlowBarMachine()
        _ = released.handle(.fnDown(cold), now: 0)
        _ = released.handle(.timer(.hold), now: 0.25)
        #expect(released.handle(.fnUp, now: 0.9).isEmpty)   // released before the model is ready: remembered
        #expect(released.handle(.modelLoaded, now: 1.5) == [.cancelTimer(.modelLoad), .finishCapture, .startTimer(.takingLonger, seconds: 8), .startTimer(.processingTimeout, seconds: 20)])
        #expect(released.state.isProcessing)

        var failed = FlowBarMachine()
        _ = failed.handle(.fnDown(cold), now: 0)
        #expect(failed.handle(.modelLoadFailed("bad file"), now: 1) ==
                [.cancelTimer(.modelLoad), .cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(failed.state == .error("Couldn't load the speech model"))
    }

    @Test("esc while loadingModel discards and tears down capture, same as esc while listening (I1)")
    func escapeWhileLoadingModel() {
        let cold = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded)
        var m = FlowBarMachine()
        _ = m.handle(.fnDown(cold), now: 0)
        #expect(m.handle(.escape, now: 1) ==
                [.cancelTimer(.hold), .cancelTimer(.doubleTap), .cancelTimer(.modelLoad), .abortCapture, .startTimer(.dismiss, seconds: 0.8)])
        #expect(m.state == .discarded)
    }

    @Test("model-load timeout behaves like a reported load failure: mic doesn't stay open forever (I1)")
    func modelLoadTimeout() {
        let cold = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .installedNotLoaded)
        var m = FlowBarMachine()
        _ = m.handle(.fnDown(cold), now: 0)
        #expect(m.handle(.timer(.modelLoad), now: 30) ==
                [.cancelTimer(.modelLoad), .cancelTimer(.hold), .cancelTimer(.doubleTap), .abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .error("Couldn't load the speech model"))
        // a modelLoaded that arrives after the timeout has nothing left to do with
        #expect(m.handle(.modelLoaded, now: 31).isEmpty)
    }

    @Test("microphone failure while listening → mic unavailable; language detection updates the chip")
    func micFailureAndLanguage() {
        var m = FlowBarMachine.listening(.pushToTalk, at: 0)
        #expect(m.handle(.languageDetected(LanguageDetection(code: "de", confidence: 0.4)), now: 1).isEmpty)
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: LanguageDetection(code: "de", confidence: 0.4))))
        #expect(m.handle(.microphoneFailed(.engineFailed("stopped")), now: 2) ==
                [.cancelTimer(.cap), .cancelTimer(.silence), .abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .micUnavailable(.inUse(by: nil)))
    }

    @Test("partial text belongs to the dictation from fn-down: recorded while armed, survives to a raw copy on timeout")
    func partialTextBeforeListening() {
        var m = FlowBarMachine()
        _ = m.handle(.fnDown(ok), now: 0)
        #expect(m.handle(.partialText("so far"), now: 0.1).isEmpty)
        #expect(m.state == .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))

        _ = m.handle(.timer(.hold), now: 0.25)
        #expect(m.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        _ = m.handle(.fnUp, now: 1)
        #expect(m.state.isProcessing)
        #expect(m.handle(.timer(.processingTimeout), now: 21) == [.abortCapture, .startTimer(.dismiss, seconds: 4)])
        #expect(m.state == .didntCatch(rawAvailable: true))
        #expect(m.handle(.copyRawRequested, now: 22) == [.copyToClipboard("so far")])

        // The same no-op-but-recorded handling also applies to the other two pre-listening states.
        var tapped = FlowBarMachine()
        tapped.state = .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil))
        #expect(tapped.handle(.partialText("still here"), now: 0.2).isEmpty)
        #expect(tapped.state == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))

        var loading = FlowBarMachine()
        loading.state = .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil))
        #expect(loading.handle(.partialText("still here"), now: 0.2).isEmpty)
        #expect(loading.state == .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
    }

    @Test("idle hint follows the default mode")
    func hints() {
        #expect(FlowBarState.idle.hint(mode: .pushToTalk) == "Hold fn to dictate")
        #expect(FlowBarState.idle.hint(mode: .handsFree) == "Press fn to dictate")
        #expect(FlowBarState.listening(Listening(mode: .handsFree, startedAt: 0, language: nil)).hint(mode: .pushToTalk) == "fn — stop")
    }
}

extension FlowBarMachine {
    static func listening(_ mode: HotkeyMode, at start: TimeInterval) -> FlowBarMachine {
        var m = FlowBarMachine()
        m.state = .listening(Listening(mode: mode, startedAt: start, language: nil))
        return m
    }
    static func processing(at start: TimeInterval) -> FlowBarMachine {
        var m = FlowBarMachine()
        m.state = .processing(Processing(startedAt: start, takingLonger: false, limitReached: false, partialText: ""))
        return m
    }
}
