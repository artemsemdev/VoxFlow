# fn-hotkey spike — results

- macOS: `26.6.2` (`sw_vers -productVersion`), build 25G83
- Run: `cd spikes/fn-hotkey && swift build && perl -e 'alarm 30; exec @ARGV' .build/debug/fn-hotkey`
- Run once, in this agent's non-interactive automated shell (no human at the keyboard, no
  ability to click into an app or physically press the fn key). One run only, as instructed.

## Raw output (verbatim, single run)

```
Accessibility trusted: true; Input Monitoring preflight: true
Secure input enabled now: false
global monitor installed — press fn a few times
Inserting into the focused element of the frontmost app…
no focused element: -25212
```

Exit code: 0 (ran to the full 20 s `RunLoop.main.run` and returned, `perl alarm` did not need
to fire).

No `fn DOWN` / `fn UP` lines were printed — no fn key press occurred during the run.

`-25212` is `kAXErrorNoValue`: `AXUIElementCopyAttributeValue` for `kAXFocusedUIElementAttribute`
on the system-wide element returned no value, i.e. no UI element accepted keyboard focus during
the run.

## Notable surprise vs. the brief's expectation

The brief anticipated this session would very likely read `Accessibility trusted: false` and
`global monitor: nil`. Instead this machine's terminal app already holds both Accessibility
*and* Input Monitoring trust (probably granted for unrelated prior work), so both preflight
checks read `true` and the global monitor installed successfully (non-nil). That part is a real,
non-fabricated observation — but it only proves the monitor *installs* when both permissions are
already granted together; it does not by itself distinguish "Accessibility alone" from
"Accessibility + Input Monitoring", because this session already has both.

## Conclusions

1. **Does the global `.flagsChanged` monitor see the fn key with Accessibility trust alone?**
   **Not observed** (permission was actually granted, but there was no human present in this
   automated session to physically press the fn key, so no `fn DOWN`/`fn UP` event was ever
   generated to confirm delivery — and because Input Monitoring was *also* already granted here,
   this run cannot isolate whether Accessibility alone would have been sufficient). Owner to run
   manually per README, ideally after first revoking Input Monitoring for the terminal app to
   isolate the Accessibility-only case, to get a real answer.

2. **Does AX `kAXSelectedTextAttribute` insertion work in TextEdit / Notes / Safari / an
   Electron app?** **Not observed** — no app was interactively focused during the 8 s window (no
   human to click into TextEdit/Notes/browser/password field in this automated session), so
   `AXUIElementCopyAttributeValue(kAXFocusedUIElementAttribute)` returned `kAXErrorNoValue`
   (-25212) and the insertion step never reached `AXUIElementSetAttributeValue`. Owner to run
   manually per README, once per target app, to get a real answer.

3. **Does `IsSecureEventInputEnabled()` flip while a password field is focused?** **Not
   observed** — the only sample taken was the baseline at launch (`false`), with no human
   available to focus a password field during the run's 8–20 s window and no fn press to trigger
   a second sample. Owner to run manually per README with a password field focused during the
   window to get a real answer.

All three answers are honest "not observed" outcomes from this non-interactive run, per the
task brief — no permissions were requested or granted by this agent, and no output was
fabricated. The owner should re-run per `README.md` in an interactive session to get real
readings for all three questions.

## Additional run (controller, same session, TextEdit frontmost via `open -a TextEdit`)

```
Accessibility trusted: true; Input Monitoring preflight: true
Secure input enabled now: false
global monitor installed — press fn a few times
Inserting into the focused element of the frontmost app…
AX set result: 0 (0 = success) role=AXList frontmost=TextEdit
```

Reading: with Accessibility (and Input Monitoring) already granted to the terminal, the global `flagsChanged`
monitor installs and `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` returns success — but the focused
element was TextEdit's document-picker list (`AXList`, no text view had focus because `make new document` over
AppleEvents timed out), so this proves the AX call path, not text insertion into a text view. Question 2 stays
"not observed" until the owner runs it with a text view focused. Question 1 still needs a physical fn press.
