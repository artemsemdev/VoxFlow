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

**Release gate:** matching the desktop interface is not proof of Mac App Store
compatibility. The desktop Accessibility insertion and global input hooks conflict
with App Sandbox. Their behavior needs an agreed adaptation and runtime validation
before this archive can be treated as a submission candidate. Do not submit a build
whose visible controls promise unavailable behavior.

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

Review screenshots use the original production views in dark mode and synthetic
content in `AppStoreReviewRenderTests`. They are test outputs, never release resources.
Inspect the complete sidebar, selected labels and native controls as well as image
size (2560 × 1600); native offscreen materials can render incorrectly even when the
test passes. Do not use an image with rendering defects. Keep private App Review
contact information in App Store Connect only.

The owner must inspect the actual matching build and final screenshots, then give
explicit approval before **Add for Review / Submit for Review**. Preparing metadata,
signing or screenshots is not approval to submit. Keep manual release enabled.
Distribution export, sandbox compatibility, export-compliance answers and Apple
review remain release gates.
