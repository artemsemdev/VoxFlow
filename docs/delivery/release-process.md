# VoxFlow v2 release process

VoxFlow is a native macOS 15+ Apple Silicon app. The archived .NET solution is on
the `v1` branch; its build/test commands do not validate v2. Issue #77 is superseded by
#115. The current milestone follows the [local-use scope in #115](https://github.com/artemsemdev/VoxFlow/issues/115#issuecomment-5634616550):
exercise Release, install with the existing local signing identity, and document launching
that installed app. That local scope is completed. The owner subsequently requested GitHub publication and
local installation of [2.1.1](2.1.1.md). Its downloadable artifact retains local signing;
Developer ID distribution and notarization remain separate work.

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
The local certificate is the intended identity for this scope. Developer ID signing and
notarization are not prerequisites for local-use acceptance.

## Version policy

Use semantic `MAJOR.MINOR.PATCH` release versions and a monotonically increasing
integer build number. Change `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`; XcodeGen applies them to `CFBundleShortVersionString` and
`CFBundleVersion`. `AppServices.appVersion` reads the bundle version for the MCP
server identity. Keep `VoxFlowVersion.string` in
`VoxFlowKit/Sources/VoxFlowCore/Version.swift` aligned as well; JSON exports use it
in their generator metadata. There is no separately versioned v2 CLI. Keep release notes and
the README status aligned with the version actually published.

For a release candidate, keep the bundle and export version numeric (`2.1.0`) and use a
unique integer build (`2` for `2.1.0-rc.1`). Record the prerelease identifier in the branch,
CHANGELOG, candidate record and artifact filename. Every replacement candidate gets a new
build number. The candidate record identifies its exact source and validation; a version
bump alone does not establish acceptance.

## Preparing a candidate for master

1. Start a release branch from current `develop`; prepare focused version/documentation changes.
2. Record owner-confirmed acceptance and any explicitly deferred checks with linked open issues.
   Deferral applies to that candidate only and does not mark an unperformed check as passed.
3. Run full app/package/script checks, warning gates, real MCP transport checks and a signed
   Release build. Record skipped opt-ins separately from passes.
4. Open a PR into `master` using the repository template. Explain that its cumulative diff
   promotes existing integration work; list new preparation changes separately.
5. Require the final PR CI result before merging. Promote with a merge commit to retain
   ancestry; create the matching version tag when publication is authorized, and merge the
   resulting release changes back into `develop`. Publish the verified archive and its checksum;
   identify signing and any unverified acceptance items in the release notes.

The older `release/2.1.0` and `release/2.1.0-rc.1` branches are historical snapshots.
Version 2.1.1 uses `release/2.1.1` and retains both the integration and master ancestry.

## Future public distribution

Developer ID signing, notarization, stapling, DMG packaging, an automated release workflow
and auto-updates remain outside the completed local-use milestone. GitHub publication of a
locally signed ZIP does not establish notarized distribution or clean-account validation.
Preserve the existing local signing configuration when preparing any future distribution.

## Local milestone acceptance

- [ ] Start with a clean tracked tree; inspect the app for local
      configuration, credentials, models, transcripts, recordings and test fixtures.
- [ ] Set the version/build number and update CHANGELOG for the installed version.
- [ ] Run the [local validation commands](../../CONTRIBUTING.md#building-and-testing)
      and the real MCP transport checks once on the integrated milestone. Check both
      complete logs and structured xcresult diagnostics for warnings.
- [ ] Build Release with `bash scripts/install.sh --build-only` and verify its identity.
- [ ] Complete the [hardware checklist](../RELEASE-CHECKLIST-2.1.0.md), including
      microphone, keyboard, Accessibility, model, device changes and real MCP clients.
- [ ] Quit the running app, install the verified Release build, verify that the installed
      signing authority and designated requirement match, then launch `/Applications/VoxFlow.app`.
- [ ] Push the validated milestone and inspect one final independent CI result;
      fix only failures not caught locally before completing the milestone.

Actual validation evidence belongs with the milestone and checklist. An unchecked
item remains pending; this document does not assert that a release has been produced.
