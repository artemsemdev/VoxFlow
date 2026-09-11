import Testing
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlow

@Suite("FlowBarContent")
struct FlowBarContentTests {
    @Test("idle, stop and retry hints follow each configured action")
    func configuredShortcuts() {
        var shortcuts = DictationShortcuts()
        shortcuts[.pushToTalk] = ShortcutBinding(keyCode: 40, modifiers: [.control, .option], label: "K")
        shortcuts[.handsFree] = ShortcutBinding(keyCode: 49, modifiers: .option, label: " ")
        #expect(!shortcuts.usesFunctionKey)
        let idle = FlowBarContent.make(state: .idle, elapsed: 0, mode: .pushToTalk, shortcuts: shortcuts)
        #expect(idle.title == "Hold ⌃ ⌥ K to dictate" && idle.trailing == .keycap("⌃ ⌥ K"))
        #expect(FlowBarContent.make(state: .idle, elapsed: 0, mode: .handsFree, shortcuts: shortcuts).title == "Press ⌥ Space to dictate")
        let stopping = FlowBarContent.make(state: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)),
                                            elapsed: 0, mode: .pushToTalk, shortcuts: shortcuts)
        #expect(stopping.trailing == .keycap("⌥ Space"))
        let retry = FlowBarContent.make(state: .didntCatch(rawAvailable: false), elapsed: 0, mode: .pushToTalk, shortcuts: shortcuts)
        #expect(retry.retryKey == "⌃ ⌥ K")
        shortcuts[.handsFree] = ShortcutAction.handsFree.defaultBinding
        let doubleTap = FlowBarContent.make(state: .idle, elapsed: 0, mode: .handsFree, shortcuts: shortcuts)
        #expect(doubleTap.title == "Double-tap fn to dictate" && doubleTap.trailing == .keycap("fn fn"))
    }
    @Test("copy per state matches the canvas")
    func copy() {
        let idle = FlowBarContent.make(state: .idle, elapsed: 0, mode: .pushToTalk)
        #expect(idle.leading == .dot(.idle) && idle.title == "Hold fn to dictate" && idle.trailing == .keycap("fn") && !idle.showsWaveform)
        #expect(FlowBarContent.make(state: .idle, elapsed: 0, mode: .handsFree).title == "Double-tap fn to dictate")

        let listening = FlowBarContent.make(state: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: LanguageDetection(code: "en", confidence: 0.4))), elapsed: 4, mode: .pushToTalk)
        #expect(listening.leading == .dot(.recording) && listening.showsWaveform && listening.timer == "0:04" && listening.trailing == .languageChip("EN?"))
        let handsFree = FlowBarContent.make(state: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)), elapsed: 84, mode: .pushToTalk)
        #expect(handsFree.trailing == .keycap("fn") && handsFree.subtitle == "stop" && handsFree.timer == "1:24")

        let processing = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")), elapsed: 1, mode: .pushToTalk)
        #expect(processing.leading == .spinner && processing.title == "Cleaning up…" && processing.subtitle == "on this Mac")
        let longer = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: true, limitReached: false, partialText: "")), elapsed: 9, mode: .pushToTalk)
        #expect(longer.title == "Taking longer…")

        #expect(FlowBarContent.make(state: .inserted(appName: "Mail", words: 42, limitReached: false), elapsed: 0, mode: .pushToTalk)
                == FlowBarContent(leading: .check, title: "Inserted into Mail", subtitle: "42 words", showsWaveform: false,
                                  timer: nil, timerIsAmber: false, trailing: nil))
        #expect(FlowBarContent.make(state: .inserted(appName: nil, words: 3, limitReached: true), elapsed: 0, mode: .pushToTalk).subtitle == "15:00 · limit reached")
        #expect(FlowBarContent.make(state: .inserted(appName: nil, words: 1, limitReached: false), elapsed: 0, mode: .pushToTalk).title == "Inserted")
        let copied = FlowBarContent.make(state: .copied, elapsed: 0, mode: .pushToTalk)
        #expect(copied.leading == .check && copied.title == "Copied — no text field here" && copied.trailing == .keycap("⌘V"))
        let didnt = FlowBarContent.make(state: .didntCatch(rawAvailable: false), elapsed: 0, mode: .pushToTalk)
        #expect(didnt.leading == .dot(.warning) && didnt.title == "Didn't catch that" && didnt.trailing == .button(.tryAgain))
        #expect(FlowBarContent.make(state: .didntCatch(rawAvailable: true), elapsed: 0, mode: .pushToTalk).trailing == .button(.copyRaw))
        // N1: `now`, not `elapsed` (which this state doesn't populate) — the paused pill's countdown
        // must not silently read as "60 min left" just because `elapsed` defaults to 0.
        let paused = FlowBarContent.make(state: .paused(until: 3600), elapsed: 0, mode: .pushToTalk, now: 120)
        #expect(paused.leading == .dot(.warning) && paused.title == "Paused" && paused.subtitle == "58 min left" && paused.trailing == .button(.resume))
        #expect(FlowBarContent.make(state: .paused(until: 3600), elapsed: 0, mode: .pushToTalk).subtitle == "60 min left")
        #expect(FlowBarContent.make(state: .discarded, elapsed: 0, mode: .pushToTalk) == FlowBarContent(leading: .cross, title: "Discarded", subtitle: nil, showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil))
        let mic = FlowBarContent.make(state: .micUnavailable(.denied), elapsed: 0, mode: .pushToTalk)
        #expect(mic.leading == .dot(.error) && mic.title == "Microphone access needed" && mic.trailing == .button(.openSettings))
        #expect(FlowBarContent.make(state: .micUnavailable(.inUse(by: nil)), elapsed: 0, mode: .pushToTalk).title == "Microphone in use by another app")
        #expect(FlowBarContent.make(state: .micUnavailable(.noDevice), elapsed: 0, mode: .pushToTalk).title == "No microphone")
        let model = FlowBarContent.make(state: .modelNotInstalled(sizeBytes: 1_624_555_275), elapsed: 0, mode: .pushToTalk)
        #expect(model.leading == .dot(.warning) && model.title == "Speech model not installed" && model.trailing == .button(.download(sizeText: "1.6 GB")))
        #expect(FlowBarContent.make(state: .excluded(app: "1Password"), elapsed: 0, mode: .pushToTalk) == FlowBarContent(leading: .excluded, title: "Dictation is off in 1Password", subtitle: nil, showsWaveform: false, timer: nil, timerIsAmber: false, trailing: nil))
        let loading = FlowBarContent.make(state: .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk)
        #expect(loading.leading == .spinner && loading.title == "Loading model…" && loading.subtitle == "keep talking")
        let err = FlowBarContent.make(state: .error("Couldn't load the speech model"), elapsed: 0, mode: .pushToTalk)
        #expect(err.leading == .dot(.error) && err.title == "Couldn't load the speech model" && err.trailing == .button(.openSettings))
        #expect(FlowBarContent.make(state: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk).showsWaveform)
    }

    @Test("timer and size formatting")
    func formats() {
        #expect(FlowBarContent.timerText(4) == "0:04")
        #expect(FlowBarContent.timerText(84) == "1:24")
        #expect(FlowBarContent.timerText(900) == "15:00")
        #expect(FlowBarContent.sizeText(1_624_555_275) == "1.6 GB")
        #expect(FlowBarContent.sizeText(487_601_967) == "480 MB")
    }

    @Test("timer turns amber 30 s from FlowBarConfig.maxDuration, not a bare literal")
    func amberThreshold() {
        let config = FlowBarConfig()
        let listening = Listening(mode: .pushToTalk, startedAt: 0, language: nil)
        let justBefore = FlowBarContent.make(state: .listening(listening), elapsed: config.maxDuration - 31, mode: .pushToTalk, config: config)
        #expect(!justBefore.timerIsAmber)
        let atThreshold = FlowBarContent.make(state: .listening(listening), elapsed: config.maxDuration - 30, mode: .pushToTalk, config: config)
        #expect(atThreshold.timerIsAmber)

        // A customised cap moves the amber threshold with it, since it comes from the config.
        var shorter = FlowBarConfig()
        shorter.maxDuration = 120
        let customised = FlowBarContent.make(state: .listening(listening), elapsed: 90, mode: .pushToTalk, config: shorter)
        #expect(customised.timerIsAmber)
    }

    @Test(".tapped renders like .armed: recording dot + waveform, no timer/chip")
    func tapped() {
        let tapped = FlowBarContent.make(state: .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk)
        #expect(tapped.leading == .dot(.recording) && tapped.showsWaveform && tapped.timer == nil && tapped.trailing == nil)
    }

    @Test("contentIdentity ignores the ticking timer, so a per-second tick doesn't retrigger FlowBarView's transition (N1)")
    func contentIdentityIgnoresTimer() {
        let listening = Listening(mode: .pushToTalk, startedAt: 0, language: LanguageDetection(code: "en", confidence: 0.9))
        let atFourSeconds = FlowBarContent.make(state: .listening(listening), elapsed: 4, mode: .pushToTalk)
        let atFiveSeconds = FlowBarContent.make(state: .listening(listening), elapsed: 5, mode: .pushToTalk)
        #expect(atFourSeconds.timer != atFiveSeconds.timer)
        #expect(atFourSeconds != atFiveSeconds)
        #expect(atFourSeconds.contentIdentity == atFiveSeconds.contentIdentity)

        // Amber flipping is also just a timer-adjacent field — identity ignores it too.
        let config = FlowBarConfig()
        let justBefore = FlowBarContent.make(state: .listening(listening), elapsed: config.maxDuration - 31, mode: .pushToTalk, config: config)
        let atThreshold = FlowBarContent.make(state: .listening(listening), elapsed: config.maxDuration - 30, mode: .pushToTalk, config: config)
        #expect(justBefore.timerIsAmber != atThreshold.timerIsAmber)
        #expect(justBefore.contentIdentity == atThreshold.contentIdentity)

        // A genuine state change (recording → processing) must still change identity.
        let processing = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")), elapsed: 4, mode: .pushToTalk)
        #expect(atFourSeconds.contentIdentity != processing.contentIdentity)
    }

    @Test("subtitleBesideTrailing / showsTitleZone pin the zone-placement properties (C7)")
    func zonePlacement() {
        let handsFree = FlowBarContent.make(state: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)), elapsed: 10, mode: .pushToTalk)
        #expect(handsFree.subtitleBesideTrailing)
        #expect(!handsFree.showsTitleZone)

        let pushToTalk = FlowBarContent.make(state: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)), elapsed: 10, mode: .pushToTalk)
        #expect(!pushToTalk.subtitleBesideTrailing)
        #expect(!pushToTalk.showsTitleZone)

        let processing = FlowBarContent.make(state: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")), elapsed: 0, mode: .pushToTalk)
        #expect(!processing.subtitleBesideTrailing)
        #expect(processing.showsTitleZone)

        let idle = FlowBarContent.make(state: .idle, elapsed: 0, mode: .pushToTalk)
        #expect(!idle.subtitleBesideTrailing)
        #expect(idle.showsTitleZone)
    }
}
