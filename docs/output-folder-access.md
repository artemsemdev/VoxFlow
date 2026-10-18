# Output folder access

The Files folder picker saves a security-scoped bookmark in local settings. On launch the app
resolves it without showing system UI, rejects stale bookmarks, and starts access before using
the restored directory. The selected folder holds one balanced access lease; each exporter keeps
that lease alive until it finishes, even if the user selects another folder meanwhile.

Old path-only settings are migrated only when the app can access a writable directory and create
a scoped bookmark. Invalid, stale, missing or denied folders fall back to the default Transcripts
directory. The Files toolbar explains the fallback until the user chooses an accessible folder.
Neither an invalid bookmark nor a failed migration silently reuses a path without authorization.
Automatic completed-job exports and result-screen exports share the same leased destination.

Inside an app's own sandbox container, Foundation can return `false` from scoped-access start
because the app already has access. Such a directory is accepted only when its canonical path
is within Foundation's current home container for the running bundle ID and it is writable.
Symlinks escaping that container and all external paths still require a successful scoped start.
Only successful starts receive a matching stop; bookmarks are still created and restored.

The app remains **unsandboxed**. Fake tests cover restoration, migration failure and balanced access
lifetimes. The opt-in test below additionally creates a disposable temporary folder, saves a real
bookmark, releases its initial lease, restores it, and exports a fixture into that folder:

```sh
TEST_RUNNER_VOXFLOW_BOOKMARK_CHECK=1 xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:VoxFlowTests/OutputFolderBookmarkIntegrationTests
```

A separate `VoxFlow Dev`-signed helper with bundle ID
`dev.artemsem.voxflow.bookmark-acceptance`, App Sandbox and user-selected read/write entitlements
also passed selection, scoped-bookmark persistence, restoration and transcript export across two
process launches inside its own container. An outside-container write probe was denied. This
validation changed neither the production app's entitlements nor its identity or privacy grants.

Neither check establishes user-selected external-folder authorization across app upgrades. A future sandboxed build
needs the appropriate user-selected-file/bookmark entitlements, stable signing, a writable default
destination, and an acceptance test selecting an external folder, quitting, relaunching, exporting,
and revoking or removing access. This change does not enable sandboxing or alter other path policies.

Apple documents [security-scoped bookmark creation](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:))
and [starting scoped access](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource()).
