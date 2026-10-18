# fn-hotkey spike

Throwaway probe used in phase 3a (#110) to answer three questions ahead of the phase 3b
HUD/hotkey UI, before writing any production code against them:

1. Does `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` see the fn key with
   **Accessibility** trust alone, or is **Input Monitoring** needed too?
2. Does `AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute, …)` insert text into
   TextEdit / Notes / Safari / a Terminal-hosted Electron app?
3. Does `IsSecureEventInputEnabled()` flip to `true` while a password field is focused?

Not built in CI, not shipped. `spikes/whisper-perf/` is the precedent for this shape of
throwaway package.

## Build

```bash
cd spikes/fn-hotkey
swift build
```

## Run

```bash
.build/debug/fn-hotkey
```

Run it directly from a real Terminal.app / iTerm session with a human at the keyboard — not
from a headless/automated shell — since the whole point is to observe permission prompts and
live key/focus events.

On first run, macOS will prompt to grant **Accessibility** to the terminal app the process runs
under (Terminal, iTerm2, etc.) — grant it, then re-run once granted (the prompt itself does not
block the process, but the trust check right after it will still read `false` until you restart
the terminal app or re-run the binary after granting).

The program prints its startup checks immediately, then waits **8 seconds** before attempting
the AX text insertion, then keeps the global fn monitor alive until **20 seconds** total have
elapsed. Use the 8-second window to:

1. Click into a **TextEdit** document window.
2. Then within the run, deliberately press the **fn** key a few times (press and release) to
   exercise the global monitor — watch for `fn DOWN` / `fn UP` lines.
3. Run the binary again (once per target app) with focus in:
   - **TextEdit** (plain text view)
   - **Notes**
   - a **browser** text field (e.g. Safari's address bar or a `<textarea>`)
   - a **password field** in System Settings (or any app's login prompt) — to observe
     `IsSecureEventInputEnabled()` flip

Each run only inserts into whichever app has focus 8 seconds after launch, so run it once per
target app rather than trying to switch focus between all four during a single 20-second run.

## What to record

For each run, capture every printed line:

- `Accessibility trusted: <bool>; Input Monitoring preflight: <bool>` — from
  `AXIsProcessTrustedWithOptions` and `CGPreflightListenEventAccess()`.
- `Secure input enabled now: <bool>` — baseline secure-input state at launch.
- `global monitor: nil (not trusted)` or `global monitor installed — press fn a few times`.
- Zero or more `fn DOWN secureInput=<bool>` / `fn UP held <n> ms` pairs — one pair per fn
  press/release while the process is running.
- `Inserting into the focused element of the frontmost app…`
- Either `no focused element: <AXError rawValue>` or
  `AX set result: <rawValue> (0 = success) role=<role> frontmost=<app name>` — and whether the
  target app's text field actually gained the inserted sentence
  (`"Hello from the VoxFlow spike. "`).

Paste the raw output per app into `RESULTS.md`, along with `sw_vers -productVersion`, and land
on one of three conclusions per question: "works with Accessibility only", "needs Input
Monitoring", or "not observed" (with the reason — e.g. no interactive session, permission not
grantable, or no human available to generate the fn/focus events during the run).
