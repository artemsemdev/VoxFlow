# Mac App Store edition

The store edition is being prepared for review; a repository change does not mean
Apple has approved or published it. Its product name is **VoxFlow: Offline
Transcription** and its bundle ID is `dev.artemsem.voxflow.store`.

The store target compiles the same application entry point, composition root and
seven screens as the desktop target: Home, History, Dictionary, Snippets, Styles,
Files and Settings. A separate reduced interface is not part of this product.

The bundle ID and macOS container are separate from the desktop release. First
launch must not import the owner's history, dictionary, snippets, preferences or
model downloads. Keychain namespaces are also separate, so store preparation does
not read or replace the desktop edition's history key or MCP token.

## Input scope

The store build uses native in-app text insertion, local shortcuts and typed snippet
expansion. It does not request Accessibility permission or install global input hooks.
A capture must begin inside VoxFlow and still be there after permission/model waits.
If the editor changes during insertion, the completed transcript is copied instead
of overwriting the user's edits. Rule pickers offer only VoxFlow in this edition.
Microphone access is required for dictation; file transcription does not need it.
The existing scratchpads remain practice areas and are not saved to History.

Selected audio/video inputs keep their security-scoped access for queued work and
retries. Exports use the sandbox Transcripts folder or a user-selected output folder.
Optional local MCP integration remains disabled by default and requires client approval.

**Release gate:** the owner must inspect the matching native build and screenshots.
Successful compilation, signing or upload is not approval to submit for Apple review.

- [Privacy policy](privacy-policy.md)
- [Support](https://github.com/artemsemdev/VoxFlow/issues)

## Build and release verification

Generate the independent project with `xcodegen generate --spec app-store.yml`,
then archive scheme `VoxFlowStore` in `VoxFlowStore.xcodeproj`. If both generated
projects are present, always pass `-project` to xcodebuild. Signing uses the
publisher's Apple team; never copy local certificates or credentials into Git.

Before any upload, verify the archive's signature and entitlements. Inspect the actual
`.app` contents: only application code, icons, privacy declarations, license notices
and the bundled Silero voice-activity model belong there. No speech model downloads,
drafts, transcripts, preferences, databases, test hosts, screenshot fixtures or
personal files may be shipped. Do not package an existing Application Support or
container directory.

Check first launch with the store bundle ID, then use synthetic speech to check
model download, file selection, recognition, history, dictionary, snippets, styles
and export under sandbox restrictions.
Retest live microphone permission and start/stop behavior separately. Local test
container data is not part of the archive.

Capture final screenshots from the running application's original screens in dark
mode, with only synthetic examples in a separate test container. Use a 1280 × 800
point window on a Retina display for a 2560 × 1600 image. Inspect every image before
uploading; offscreen AppKit sidebar materials can produce incorrect label colors
even when render tests pass. Do not substitute hand-drawn controls or use defective
captures. Screenshots and synthetic data are never bundled into the release.
Keep private App Review contact information in App Store Connect only.

The owner must inspect the actual matching build and final screenshots, then give
explicit approval before **Add for Review / Submit for Review**. Preparing metadata,
signing or screenshots is not approval to submit. Keep manual release enabled.
Live microphone start/stop, export-compliance and content-rights answers, publication
of privacy responses, owner approval and Apple review remain release checks.

## Candidate validation (2.1.1, build 5)

- Signed sandbox archive and App Store package export succeeded. Upload completed;
  this is a preparation build, not an Apple review submission or public release.
- Inspected all 19 bundle files: no user databases, preferences, transcripts, speech
  model downloads, test audio or screenshot fixtures are packaged.
- Native file import, local Whisper small recognition and sandbox TXT export succeeded
  using synthetic garden narration. Native typed snippet expansion also succeeded.
- Focus changes, manual edits, cancellation, Unicode cursor placement, local shortcut
  lifecycle, scoped file access and in-app preflight/rule selection have automated tests.
- Microphone permission and real microphone capture are left for the owner to test.
