# VoxFlow v2 release process

VoxFlow is a native macOS 15+ Apple Silicon app. The archived .NET solution is on
the `v1` branch; its build/test commands do not validate v2. Issue #77's release
planning is implemented here; #115 tracks executable release and distribution acceptance.

## Local Release build and installation

Configure the stable `VoxFlow Dev` identity in `Local.xcconfig` as described in
[SETUP.md](../../SETUP.md#local-code-signing-once-per-mac). Both Debug and Release
use `Signing.xcconfig`. Do not switch an existing install to ad-hoc signing.

```sh
bash scripts/install.sh --build-only
# Quit VoxFlow, then build, verify and replace /Applications/VoxFlow.app:
bash scripts/install.sh
open /Applications/VoxFlow.app
```

The script builds Release locally, rejects warnings in the complete build log,
verifies the signature and bundle identifier, stages the app on the destination
filesystem, and checks its designated signing requirement against an existing
install before replacement. A failed final verification restores the previous app.
If restoration itself fails, the backup is retained at the printed path.
The script never changes privacy grants, Keychain contents, models or history.
It does not quit the running app or elevate privileges. `/Applications` must be
writable by the invoking user; build-only remains usable without install access.

Release build products are in `build/local-release/Build/Products/Release`;
the full build log is `build/local-release.log`. Generated files are ignored by Git.
This local certificate is not a Developer ID certificate and does not establish
notarized distribution acceptance.

## Version policy

Use semantic `MAJOR.MINOR.PATCH` release versions and a monotonically increasing
integer build number. Change `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`; XcodeGen applies them to `CFBundleShortVersionString` and
`CFBundleVersion`. `AppServices.appVersion` reads the bundle version for the MCP
server identity. There is no separately versioned v2 CLI. Keep release notes and
the README status aligned with the version actually published.

Cut `release/x.y.z` from validated `develop`. Tag its released commit `vx.y.z` on
`master`, then merge the release back to `develop`. Do not move an existing tag.
Backend artifact tags such as `whisper-v1.9.2-voxflow.1` are separate from app releases.

## External distribution path

Issue #115 owns the implementation and acceptance for public distribution; no
additional duplicate implementation issue is needed. The first external artifact
is a `.dmg` containing a Developer ID signed, notarized `.app` and an Applications
link. A `.pkg`, App Store submission and auto-update service are out of scope.

Prerequisites: paid Apple Developer Program membership, a valid Developer ID
Application certificate with its private key, its Team ID, and credentials stored
in a `notarytool` Keychain profile. Never commit credentials or local export options.
Use a separate distribution signing override with hardened runtime enabled; preserve
the local identity for existing local installations. Signing alone does not require
App Sandbox; #132's bookmark requirement applies if sandboxing is introduced.

The distribution pipeline is archive → export the signed `.app` → submit with
`xcrun notarytool submit --keychain-profile <profile> --wait` → staple and validate
the app → create a `.dmg` → notarize/staple the disk image → assess with `spctl`
and test installation in a clean account → checksum and publish. Record the
notarization IDs with the release evidence. Passing local self-signature checks
must never be reported as passing Developer ID, Gatekeeper or notarization checks.

## Before tagging

- [ ] Start with a clean tracked release tree; inspect the app and archive for local
      configuration, credentials, models, transcripts, recordings and test fixtures.
- [ ] Set the version/build number, update CHANGELOG and prepare release notes.
- [ ] Run the [local validation commands](../../CONTRIBUTING.md#building-and-testing)
      and the real MCP transport checks once on the integrated milestone. Check both
      complete logs and structured xcresult diagnostics for warnings.
- [ ] Build Release with `bash scripts/install.sh --build-only` and verify its identity.
- [ ] Complete the [hardware checklist](../RELEASE-CHECKLIST-2.1.0.md), including
      microphone, keyboard, Accessibility, model, device changes and real MCP clients.
- [ ] For external distribution, record successful notarization/stapling, mount the
      `.dmg`, install on a clean account and pass `spctl --assess --type execute`.
- [ ] Compute `shasum -a 256 VoxFlow-x.y.z.dmg > SHA256SUMS` for the final artifact;
      attach that exact artifact, checksum and release notes to the GitHub release.
- [ ] Push the validated milestone and inspect one final independent CI result;
      fix only failures not caught locally before tagging/publishing.

Actual validation evidence belongs in the release PR and checklist. An unchecked
item remains pending; this document does not assert that a release has been produced.
