# VoxFlow 2.1.0 — release checklist

Everything on `release/2.1.0` that only a person on a real Mac can verify, gathered from the
phase 3, 4, 5 and 6 plans and ordered so you can work straight down the list in one sitting.
Automated tests cover the rest: 477 app tests, 363 package tests, 15 script tests, and a ten-case
loopback integration suite, all green on this branch.

**Tick as you go. If something fails, stop and note which line — every item maps to code that can
be fixed without touching the others.**

## Before you start

- [ ] `git checkout release/2.1.0 && git pull`
- [ ] `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build`
- [ ] Confirm the build is signed with your own certificate, not ad-hoc:
      `codesign -dvv <path to VoxFlow.app>` prints `Authority=VoxFlow Dev`.
      (If it does not, see SETUP.md → "Local code signing". Without it macOS re-asks for
      Microphone and Accessibility on every rebuild.)
- [ ] Grant Microphone and Accessibility to this build once, if you have not since creating the
      certificate.
- [ ] Have a speech model installed (Settings › Models). Download `large-v3-turbo` on a 16 GB Mac
      or `small` on 8 GB.

## 1. First launch and onboarding (phase 3)

Reset onboarding first so you see it:

```sh
defaults write dev.artemsem.voxflow voxflow.onboarding.completed -string 0
defaults write dev.artemsem.voxflow voxflow.onboarding.step -string 0
```

- [ ] Launch: the onboarding window opens instead of the main window.
- [ ] Walk all five steps: welcome → grant Microphone with the button and Accessibility through
      System Settings → choose hands-free or push-to-talk → the model step shows "Installed" (or
      downloads) → the try-it step inserts dictated text into its scratchpad.
- [ ] The main window opens on Home afterwards.
- [ ] The try-it dictation did **not** create a History row (it is deliberately suppressed).

## 2. Dictation end to end (phase 3)

- [ ] Open TextEdit, hold fn, say a sentence, release: the Flow Bar shows listening → processing,
      and the text lands in TextEdit.
- [ ] A History row appears for it. Expand it, use Copy, then Delete, then Undo — the row returns.
- [ ] Settings › Privacy: turn encryption **off** → existing rows read "Encrypted — …" → turn it
      back **on** → they are readable again.
- [ ] Settings › Audio: set silence-stop to 5 s, switch to hands-free, dictate — the capture ends
      after about 5 s of silence.
- [ ] Try dictating into a field where Accessibility insertion cannot work (a password field): the
      text goes to the clipboard with the ⌘V hint instead of failing.

## 3. Dictionary, snippets and per-app styles (phase 4a)

- [ ] Dictionary: add an unusual word (a name, a product), dictate it — it is recognised rather
      than mis-heard.
- [ ] Snippets: create one with trigger `/sig`, then dictate "slash sig" — the body is expanded
      into the text.
- [ ] Styles: set the Mail override to Formal, dictate into Mail — contractions are expanded
      ("can't" → "cannot").
- [ ] History: expand one of those rows — the style used is shown in the row's meta line.
- [ ] Dictionary: turn on "Learn names from Contacts", grant the prompt — names are imported.
      Then revoke Contacts in System Settings — the toggle snaps back off.

## 4. Home, Settings and the menu bar (phase 4b)

- [ ] Home stats change after two real dictations.
- [ ] Revoke a granted permission in System Settings — the first-run Setup card reappears on Home.
- [ ] Settings › General: launch-at-login, appearance, Flow Bar position and sounds all apply
      immediately. If you deny the login-item registration, the toggle snaps back off.
- [ ] Settings › MCP Server: endpoint Copy, token Copy, and Regenerate (with its confirmation)
      all work.
- [ ] Menu bar dropdown: every item navigates where it says. "Pause dictation for 1 hour" makes
      the Flow Bar pill read "Paused · N min left" and hide itself after about 3 s; Resume, from
      either the pill or the dropdown, clears it.
- [ ] With the main window in the background, finish a model download — a notification reads
      "{model} installed. Ready to use offline." and clicking it opens Settings › Models.
- [ ] With the main window in the background, finish a file transcription — a notification reads
      "{file} transcribed · {duration} · {FORMAT} saved to ~/Transcripts" and clicking it opens
      that file's result.

## 5. On-device style cleanup (phase 5)

Needs the 2.1 GB Qwen model.

- [ ] Settings › Models: download "Qwen2.5 3B Instruct (4-bit)" — progress shown, checksum
      verified, row reads "Installed".
- [ ] Dictate the same sentence with Formal, then Casual, then Very casual selected on the Styles
      page: each tone's output is visibly different and style-appropriate, not just the fixed rule
      transforms.
- [ ] Remove the model — dictation still works and falls back to rule-based styling, with no crash
      and no hang.
- [ ] History → pick a row → "Re-style ▾" → choose another tone: the row updates in place and the
      clipboard holds the new text.
- [ ] Files → open a result → check "Apply Casual cleanup": segments change, and "Save as…" writes
      the cleaned text rather than the raw transcript.
- [ ] First launch after installing the model: no freeze while it warms up in the background.

## 6. The MCP server (phase 6)

Needs Cursor installed. Full instructions with the config snippet:
[docs/runbooks/connect-an-mcp-client.md](runbooks/connect-an-mcp-client.md).

- [ ] Settings › MCP Server: turn on "Enable MCP server".
- [ ] Copy the access token, add the Cursor snippet to `~/.cursor/mcp.json` with it, restart Cursor.
- [ ] **Close VoxFlow's main window**, then have Cursor call a tool: the approval dialog still
      appears, shows Cursor's name, pid and executable path, and "Always allow" works.
- [ ] Run `transcribe_file` from Cursor on a real audio file — the returned text is correct.
- [ ] Run `dictate` from Cursor: speak, the Flow Bar shows the capture, and the returned text
      matches what you said and was inserted and saved like a normal dictation.
- [ ] Turn on `search_history`, run it from Cursor — it returns real History hits.
- [ ] Revoke the client from Connected clients — the next call from Cursor fails.
- [ ] Regenerate the token — Cursor is disconnected and Connected clients is empty.
- [ ] Occupy the default port (`nc -l 7331` in a terminal), restart the server — the endpoint moves
      to 7332 and Settings shows the note telling you to re-copy it.

## When everything is ticked

Tell me and I will: merge `release/2.1.0` into `master`, tag `v2.1.0`, merge back into `develop`,
publish the GitHub release, and close #110 (phase 3, the last phase issue still open by design).

Phase 7 (#115, a signed and notarised `.dmg`) is separate and needs a Developer ID certificate
from a paid Apple Developer account before it can be built.
