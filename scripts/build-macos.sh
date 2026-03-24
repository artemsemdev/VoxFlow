#!/bin/bash
set -euo pipefail

echo "Building VoxFlow Desktop for macOS..."

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)
        RID="maccatalyst-x64"
        ;;
    arm64)
        RID="maccatalyst-arm64"
        ;;
    *)
        echo "Unsupported host architecture: $HOST_ARCH" >&2
        exit 1
        ;;
esac

dotnet publish src/VoxFlow.Desktop/VoxFlow.Desktop.csproj \
    -f net9.0-maccatalyst \
    -c Release \
    -r "$RID" \
    -p:CreatePackage=true

echo "Build artifacts in: src/VoxFlow.Desktop/bin/Release/net9.0-maccatalyst/$RID/publish/"

# Generate SHA-256 checksum
APP_PATH=$(find src/VoxFlow.Desktop/bin/Release -name "*.pkg" -o -name "*.app" 2>/dev/null | head -1)
if [ -n "$APP_PATH" ]; then
    shasum -a 256 "$APP_PATH" > "${APP_PATH}.sha256"
    echo "Checksum: ${APP_PATH}.sha256"
fi
