# Mac App Store upload: 2.1.1 (5)

This branch records the candidate uploaded to App Store Connect on 1 November
2026. Uploading is not submission for App Review or publication.

| Field | Value |
| --- | --- |
| Git branch | `release/2.1.1-mac-app-store-build.5` |
| Product | VoxFlow: Offline Transcription |
| Platform / architecture | macOS 15+, arm64 |
| Version / build | `2.1.1` / `5` |
| Bundle ID | `dev.artemsem.voxflow.store` |
| App Store Connect app ID | `6829487308` |
| Scheme / configuration | `VoxFlowStore` / `Release` |
| Project specification | `app-store.yml` |
| Archive created | 2026-11-01 20:30:46 Europe/Berlin |
| Upload completed | 2026-11-01 20:33:01 Europe/Berlin |
| Recorded upload result | `success`, no errors or warnings |
| Release mode | Manual; owner approval required before review submission |

## Source and artifact provenance

The local reflog and archive log place the build at source checkpoint
`a205067dc2d6e55e87c91341ac62ca0b206304fe`. The release branch starts from integrated
commit `89eff7f177444fec887e15cdd6c0e1d6c9b4c6d4`; its application code, package code,
store resources and build specification are identical to that checkpoint. Only
README, changelog and App Store documentation differ. The archive does not embed a
Git SHA, so this mapping was reconstructed from those local records.

The uploaded archive is retained locally at
`build/app-store/VoxFlow-upload.xcarchive`. Its `Info.plist` records the successful
App Store upload and build number. The archived `Contents/MacOS/VoxFlow` SHA-256 is:

```text
07e613a479a506b37d03899a81a3680998deb7e9415db559a6dec5413ba92df8
```

This hash identifies the local archived executable before Apple's processing;
it is not a hash of an App Store download. Archives and signing material are not
committed to Git. The pre-existing `release/2.1.1` branch describes desktop build 3
and must not be used to identify this store upload.

## Scope and review state

The original seven-section interface is retained. Dictation and typed snippets
operate inside VoxFlow in the sandboxed store edition. The uploaded bundle contains
no personal data or marketing fixtures. Demo content was generated in the separate
`dev.artemsem.voxflow.store.capture` container for six marketing screenshots and is
not part of this release's source roots or archive.

The candidate remains subject to the owner's UI and live-microphone checks and the
remaining App Store declarations documented in [the store guide](../app-store/README.md).
No App Review submission, stable release tag or public release is implied by this
branch. Do not rebuild or replace build 5 and describe the result as the same upload;
use a new build number for a subsequent binary.
