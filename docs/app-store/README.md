# Mac App Store edition

The store edition is being prepared for review; a repository change does not mean
Apple has approved or published it. Its product name is **VoxFlow: Offline
Transcription** and its bundle ID is `dev.artemsem.voxflow.store`.

It provides local in-app dictation, an editable saved draft, copying, audio/video
file transcription and TXT/SRT/VTT/JSON/Markdown export. Speech models download on
demand. It requires macOS 15 or later on Apple silicon.

The sandbox edition has a separate entry point and storage container. It does not
include system-wide insertion, Accessibility access, global dictation shortcuts,
MCP servers, the full app's history database or LLM rewriting. It leaves data from
the separately distributed desktop app in place.

- [Privacy policy](privacy-policy.md)
- [Support](https://github.com/artemsemdev/VoxFlow/issues)

## Build and release verification

Generate the independent project with `xcodegen generate --spec app-store.yml`,
then archive scheme `VoxFlowStore` in `VoxFlowStore.xcodeproj`. If both generated
projects are present, always pass `-project` to xcodebuild. Signing uses the
publisher's Apple team; never copy local certificates or credentials into Git.

Before upload, verify the archive's signature and entitlements. Inspect the actual
`.app` contents: only application code, icons, privacy declarations, license notices
and the bundled Silero voice-activity model belong there. No speech model downloads,
drafts, transcripts, preferences, databases, test hosts, screenshot fixtures or
personal files may be shipped. Do not package an existing Application Support or
container directory.

Check first launch with the store bundle ID, then use synthetic speech to check
model download, file selection, recognition and export under sandbox restrictions.
Retest live microphone permission and start/stop behavior separately. Local test
container data is not part of the archive.

Store screenshots are rendered from the real production views using synthetic
content in `StoreRenderTests`; they are not release resources. Generate JPEGs at
2560 × 1600 and inspect every image before upload. Keep private App Review contact
information in App Store Connect only.

App Store processing, distribution signing, export-compliance answers and Apple
review remain release gates. Use manual release so an approved version does not
go live before the publisher is ready.
