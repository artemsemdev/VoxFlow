# Physical acceptance — VoxFlow remaining issues

Record the app path/build, macOS version, input device, selected speech model, date, and observed result for each check. Use disposable TextEdit documents and non-sensitive speech.
Status reconciled with GitHub and the owner on 2026-10-19. The owner confirmed #110 and #138;
#161 passed real TextEdit acceptance on 2026-09-12. These are historical/owner results, not a
claim that all checks were rerun against the new candidate. A fake, render, or synthetic-key
test does not certify physical keyboard/microphone behavior.

For [2.1.0-rc.1](delivery/2.1.0-rc.1.md), the owner explicitly deferred #137, #139, #144, #145
and #162. Their boxes remain unchecked and their issues remain open. This exception applies
to preparing this candidate; final stable acceptance requires a separate decision.

## 1. Keyboard and speech


- [x] [#110](https://github.com/artemsemdev/VoxFlow/issues/110): Owner confirmed dictation works on 2026-10-19; issue closed. The specific permission-revocation scenario remains tracked separately in #144 below.
- [ ] [#162](https://github.com/artemsemdev/VoxFlow/issues/162): Record a supported custom push-to-talk shortcut, then physically hold/speak/release it in TextEdit. Expect the saved binding to start and stop capture correctly; reopening Hotkeys retains it.
- [ ] #162: Use the configured hands-free shortcut twice to start/stop. Use the configured cancel key during preparation/model loading and during active capture. Expect cancellation to prevent a late recording or late insertion. Record preparation cancellation as untested if that state was never exercised.
- [ ] #162: After a successful dictation, focus a fresh disposable target and invoke Re-insert last. Expect the last transcript in the new field and no duplicate History row.
- [ ] [#137](https://github.com/artemsemdev/VoxFlow/issues/137): Dictate for 30 seconds into TextEdit. Expect text to appear before release, with the final text correct after stopping. In a second capture, press Esc after a partial insertion: existing text stays and FB-06 appears.
- [ ] #137 scope follow-up: Switch focus during capture. Expect no writes to the new field; the completed transcript is available through clipboard fallback.

## 2. Real TextEdit caret — #161

- [x] [#161](https://github.com/artemsemdev/VoxFlow/issues/161): Real TextEdit fixture verified exact expanded `/sig` text after existing content and the selected range at `{cursor}` on 2026-09-12; issue closed. [Acceptance evidence](https://github.com/artemsemdev/VoxFlow/issues/161#issuecomment-5648844816).
- Agent can run the insertion-only fixture without microphone speech once the test-host app already has Accessibility permission and a disposable TextEdit document is prepared and activated. Do not prompt for permission from the test or alter an unrelated document.
- Exact document: `VOXFLOW-161-CURSOR-CHECK` followed by one newline; caret at its end. Activate it after the fixture prints its readiness message.
- Exact opt-in: `TEST_RUNNER_VOXFLOW_AX_CARET_CHECK=1 xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -destination 'platform=macOS,arch=arm64' test -only-testing:VoxFlowTests/SnippetCaretIntegrationTests` (reuse the project's derived-data path).
- The fixture verifies existing AX trust, frontmost TextEdit, exact scratch contents and selection before writing. This can establish the issue's real caret requirement, but does not replace spoken snippet/global-keyboard acceptance.

## 3. Permission and hardware transitions

- [ ] [#144](https://github.com/artemsemdev/VoxFlow/issues/144): Owner revokes VoxFlow Accessibility permission in System Settings, then dictates into TextEdit. Expect `Can't type here · Open Settings`, no lost transcript (paste it into the scratch document), and the action opens the Accessibility pane. Restore permission afterward if desired. This also exercises #110's unavailable-insertion fallback.
- [ ] [#139](https://github.com/artemsemdev/VoxFlow/issues/139): With Settings › Audio open, connect/switch/disconnect/reconnect real input hardware while idle and during capture. Expect the displayed default input to follow changes; supported named switches preserve capture, complete device loss shows no-device/aborts, and reconnection allows recovery. Compare speech before/after a restart gap: timestamps remain continuous without fabricated silence or duplicated words. Record the actual devices and recovery behavior.
- [x] [#138](https://github.com/artemsemdev/VoxFlow/issues/138): Owner confirmed the exclusive-microphone scenario works on 2026-10-19; issue closed. The original procedure covers the named busy HUD, retry after hog-mode release and cancellation of the wait.
- [ ] [#145](https://github.com/artemsemdev/VoxFlow/issues/145): Start transcribing a genuine ten-minute audio file, then dictate a sentence into TextEdit while it is still running. Expect insertion before the 20-second processing timeout, followed by continued file progress/completion. Retain both results to check for missing/repeated words or timestamp discontinuities.

## Existing evidence and division of work

| Issue | Existing automated evidence; what remains |
| --- | --- |
| #110 | Owner confirmed working on 2026-10-19; closed. Explicit permission revocation remains #144. |
| #137 | Fake controller/AX-target tests cover cumulative windows, tail correction, cancellation and focus loss. They do not prove live text appears during a real 30-second recording. |
| #162 | Recorded/persisted shortcuts, reserved/conflicting bindings, live-monitor command wiring, cancellation, privacy-checked reinsertion and canvas renders passed. Real global keyboard/target behavior remains. |
| #161 | UTF-16/Unicode unit tests and the guarded real TextEdit caret fixture passed; closed on 2026-09-12. |
| #144 | Reasoned fallback, HUD copy/action routing and native renders passed. Permission revocation plus real insertion/clipboard behavior remains. |
| #139 | Fake device/restart/listener tests cover offsets, stale events and idle updates. Actual switching, unplugging and reconnecting remain. |
| #138 | Fake coverage and real USB ownership notifications passed; owner confirmed the app scenario on 2026-10-19; closed. |
| #145 | ADR-009 and fake prioritized-engine tests establish bounded dictation latency. Real concurrent file/microphone acceptance remains. |

Agent can autonomously inspect current logs/build identity, enumerate available inputs, prepare disposable fixtures, inspect exported timestamps, and run narrowly scoped existing opt-ins when their prerequisites are met. These checks do not substitute for the missing physical observations.
Physical participation is needed for actual key gestures/speech, owner-controlled permission changes, and hardware connection changes; #138 additionally needs compatible hog-mode hardware/software. Mark unavailable conditions as unverified, not passed.
