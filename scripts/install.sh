#!/bin/bash
# Build and verify a Release app using the same stable local signing identity as Debug.
set -euo pipefail
release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_build_only=0
if [[ "${1:-}" == "--build-only" ]]; then
    release_build_only=1
    shift
fi
if [[ $# -ne 0 ]]; then
    echo "Usage: bash scripts/install.sh [--build-only]" >&2
    exit 2
fi
cd "$release_root"
release_derived="$release_root/build/local-release"
release_log="$release_root/build/local-release.log"
mkdir -p "$release_root/build"
xcodegen generate
xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$release_derived" \
    build > "$release_log" 2>&1 || {
        tail -60 "$release_log"
        exit 1
    }
python3 scripts/check_build_logs.py "$release_log"
release_app="$release_derived/Build/Products/Release/VoxFlow.app"
python3 scripts/install_app.py "$release_app" --verify-only
if [[ "$release_build_only" == 1 ]]; then
    echo "Verified Release build: $release_app"
else
    python3 scripts/install_app.py "$release_app"
fi
